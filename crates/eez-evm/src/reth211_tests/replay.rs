//! Complete-state trie oracle: expected values are calculated without executing the candidate.
//! Recovered senders are supplied explicitly; this test does not validate ECDSA or signing identity.
use super::*;
use alloy_consensus::TxReceipt;
use alloy_primitives::keccak256;
use reth_trie_common::{HashBuilder, Nibbles, TrieAccount, proof::ProofRetainer};

fn trie(mut leaves: Vec<(B256, Vec<u8>)>) -> (B256, Vec<Bytes>) {
    leaves.sort_unstable_by_key(|(key, _)| *key);
    assert!(leaves.windows(2).all(|pair| pair[0].0 != pair[1].0));
    let retainer = ProofRetainer::new(leaves.iter().map(|(key, _)| Nibbles::unpack(key)).collect());
    let mut builder = HashBuilder::default().with_proof_retainer(retainer);
    for (key, value) in leaves {
        builder.add_leaf(Nibbles::unpack(key), &value);
    }
    let root = builder.root();
    (
        root,
        builder
            .take_proof_nodes()
            .into_nodes_sorted()
            .into_iter()
            .map(|(_, node)| node)
            .collect(),
    )
}
fn complete_state(db: &InMemoryDB) -> (B256, Vec<Bytes>) {
    let mut leaves = Vec::new();
    let mut nodes = Vec::new();
    for (address, info) in &db.cache.accounts {
        let Some(info) = info else { continue };
        let storage = db
            .cache
            .storage
            .get(address)
            .map(|s| {
                s.slots
                    .iter()
                    .filter(|(_, value)| !value.is_zero())
                    .map(|(key, value)| {
                        (keccak256(key.to_be_bytes::<32>()), alloy_rlp::encode(value))
                    })
                    .collect()
            })
            .unwrap_or_default();
        let (storage_root, storage_nodes) = trie(storage);
        nodes.extend(storage_nodes);
        leaves.push((
            keccak256(address),
            alloy_rlp::encode(TrieAccount {
                nonce: info.nonce,
                balance: info.balance,
                storage_root,
                code_hash: info.code_hash,
            }),
        ));
    }
    let (root, state_nodes) = trie(leaves);
    nodes.extend(state_nodes);
    (root, nodes)
}
fn expected(mut db: InMemoryDB, parent_hash: B256, count: u64, fee: u64) -> B256 {
    // EIP-2935 writes the inclusion parent's hash into slot (block_number - 1) % 8191.
    db.insert_account_storage(
        &alloy_eips::eip2935::HISTORY_STORAGE_ADDRESS,
        &U256::ZERO,
        &U256::from_be_bytes(parent_hash.0),
    );
    let paid = U256::from(fee) * U256::from(21_000 * count);
    let mut user = db.get_account(&USER).unwrap().unwrap();
    user.nonce = count;
    user.balance -= paid + U256::from(if count == 1 { 11 } else { 24 });
    db.insert_account_info(&USER, user);
    db.insert_account_info(&COLLECTOR, AccountInfo::empty().with_balance(paid));
    for address in [SYSTEM_ADDRESS, EEZL2_ADDRESS] {
        let mut info = db.get_account(&address).unwrap().unwrap();
        info.balance = U256::ZERO;
        db.insert_account_info(&address, info);
    }
    complete_state(&db).0
}

#[test]
fn stateless_closed_prefixes_and_terminal_root_match_independent_account_oracle() {
    let (config, db) = fixture(bytes!("00"));
    let (pre_root, nodes) = complete_state(&db);
    let mut parent = parent(&config, 5);
    parent.state_root = pre_root;
    let base_fee = parent
        .next_block_base_fee(eez_protocol::l2::BASE_FEE_PARAMS)
        .unwrap();
    let txs: Vec<EezTxEnvelope> = [(SYSTEM_ADDRESS, 11), (EEZL2_ADDRESS, 13)]
        .into_iter()
        .enumerate()
        .map(|(nonce, (to, value))| {
            TxLegacy {
                chain_id: Some(901),
                nonce: nonce as u64,
                gas_limit: 21_000,
                gas_price: u128::from(base_fee),
                to: TxKind::Call(to),
                value: U256::from(value),
                ..Default::default()
            }
            .into_signed(Signature::new(U256::ONE, U256::ONE, false))
            .into()
        })
        .collect();
    let receipts: Vec<eez_primitives::Receipt> = (1..=2)
        .map(|count| eez_primitives::Receipt {
            tx_type: eez_primitives::EezTxType::Ethereum(alloy_consensus::TxType::Legacy),
            success: true,
            cumulative_gas_used: count * 21_000,
            logs: Vec::new(),
        })
        .collect();
    let root1 = expected(db.clone(), parent.hash_slow(), 1, base_fee);
    let root2 = expected(db.clone(), parent.hash_slow(), 2, base_fee);
    let header = Header {
        number: 1,
        timestamp: 5,
        parent_hash: parent.hash_slow(),
        gas_used: 42_000,
        base_fee_per_gas: Some(base_fee),
        state_root: root2,
        transactions_root: alloy_consensus::proofs::calculate_transaction_root(&txs),
        receipts_root: alloy_consensus::proofs::calculate_receipt_root(
            &receipts
                .iter()
                .map(|r| r.with_bloom_ref())
                .collect::<Vec<_>>(),
        ),
        ..parent.clone()
    };
    let block = eez_primitives::Block::new(
        header,
        alloy_consensus::BlockBody {
            transactions: txs,
            withdrawals: Some(Default::default()),
            ..Default::default()
        },
    );
    let witness = alloy_rpc_types_debug::ExecutionWitness {
        state: nodes,
        codes: db
            .cache
            .contracts
            .values()
            .map(Bytecode::original_bytes)
            .collect(),
        headers: vec![alloy_rlp::encode(&parent).into()],
        ..Default::default()
    };
    let recovered =
        reth_primitives_traits::RecoveredBlock::new_unhashed(block.clone(), vec![USER, USER]);
    let result = crate::stateless::validate_with_closed_prefixes(
        recovered,
        witness.clone(),
        config.chain_spec().clone(),
        config.clone(),
        &[0, 1],
    )
    .unwrap();
    assert_eq!(result.validation.post_state_root, root2);
    assert_eq!(
        result
            .checkpoints
            .transaction_state_checkpoints
            .iter()
            .map(|c| c.state_root)
            .collect::<Vec<_>>(),
        vec![root1, root2]
    );
    assert_eq!(result.validation.execution_output.result.receipts, receipts);
    let mut invalid = block;
    invalid.header.state_root = root1;
    let invalid = reth_primitives_traits::RecoveredBlock::new_unhashed(invalid, vec![USER, USER]);
    assert!(matches!(
        crate::stateless::validate_with_closed_prefixes(
            invalid,
            witness,
            config.chain_spec().clone(),
            config,
            &[0, 1]
        ),
        Err(stateless_reth::validation::StatelessValidationError::PostStateRootMismatch { .. })
    ));
}

#[test]
fn absent_system_value_group_replays_against_independent_terminal_trie() {
    let (config, mut db) = fixture(bytes!("00"));
    db.cache.accounts.remove(&SYSTEM_ADDRESS);
    let (pre_root, nodes) = complete_state(&db);
    let mut parent = parent(&config, 5);
    parent.state_root = pre_root;
    let fee = parent
        .next_block_base_fee(eez_protocol::l2::BASE_FEE_PARAMS)
        .unwrap();
    let txs: Vec<EezTxEnvelope> = vec![
        load(5).into_inner(),
        TxLegacy {
            chain_id: Some(901),
            nonce: 0,
            gas_limit: 21_000,
            gas_price: u128::from(fee),
            to: TxKind::Call(EEZL2_ADDRESS),
            value: U256::from(3),
            ..Default::default()
        }
        .into_signed(Signature::new(U256::ONE, U256::ONE, false))
        .into(),
    ];
    // Independently calculated Osaka floor for the native selector followed by STOP.
    let native_gas = 21_000
        + LOAD_EXECUTION_TABLE_SELECTOR
            .iter()
            .map(|b| if *b == 0 { 10u64 } else { 40 })
            .sum::<u64>();
    let receipts = vec![
        eez_primitives::Receipt {
            tx_type: eez_primitives::EezTxType::System,
            success: true,
            cumulative_gas_used: native_gas,
            logs: vec![],
        },
        eez_primitives::Receipt {
            tx_type: eez_primitives::EezTxType::Ethereum(alloy_consensus::TxType::Legacy),
            success: true,
            cumulative_gas_used: native_gas + 21_000,
            logs: vec![],
        },
    ];
    let mut expected = db.clone();
    expected.insert_account_storage(
        &alloy_eips::eip2935::HISTORY_STORAGE_ADDRESS,
        &U256::ZERO,
        &U256::from_be_bytes(parent.hash_slow().0),
    );
    let paid = U256::from(fee) * U256::from(21_000);
    let mut user = expected.get_account(&USER).unwrap().unwrap();
    user.nonce = 1;
    user.balance -= paid + U256::from(3);
    expected.insert_account_info(&USER, user);
    expected.insert_account_info(&COLLECTOR, AccountInfo::empty().with_balance(paid));
    // Group cleanup discards the native five wei and the user's three wei; SYSTEM stays absent.
    let root = complete_state(&expected).0;
    let header = Header {
        number: 1,
        timestamp: 5,
        parent_hash: parent.hash_slow(),
        gas_used: native_gas + 21_000,
        base_fee_per_gas: Some(fee),
        state_root: root,
        transactions_root: alloy_consensus::proofs::calculate_transaction_root(&txs),
        receipts_root: alloy_consensus::proofs::calculate_receipt_root(
            &receipts
                .iter()
                .map(|r| r.with_bloom_ref())
                .collect::<Vec<_>>(),
        ),
        ..parent.clone()
    };
    let block = eez_primitives::Block::new(
        header,
        alloy_consensus::BlockBody {
            transactions: txs,
            withdrawals: Some(Default::default()),
            ..Default::default()
        },
    );
    let witness = alloy_rpc_types_debug::ExecutionWitness {
        state: nodes,
        codes: db
            .cache
            .contracts
            .values()
            .map(Bytecode::original_bytes)
            .collect(),
        headers: vec![alloy_rlp::encode(&parent).into()],
        ..Default::default()
    };
    let recovered = reth_primitives_traits::RecoveredBlock::new_unhashed(
        block.clone(),
        vec![SYSTEM_ADDRESS, USER],
    );
    let out = crate::stateless::validate_with_closed_prefixes(
        recovered,
        witness.clone(),
        config.chain_spec().clone(),
        config.clone(),
        &[1],
    )
    .unwrap();
    assert_eq!(out.validation.post_state_root, root);
    assert_eq!(
        out.checkpoints.transaction_state_checkpoints[0].state_root,
        root
    );
    assert_eq!(out.validation.execution_output.result.receipts, receipts);
    assert!(
        !out.validation
            .execution_output
            .state
            .state
            .contains_key(&SYSTEM_ADDRESS)
    );
    // A persisted empty SYSTEM account is a different root, not an accepted equivalent encoding.
    expected.insert_account_info(&SYSTEM_ADDRESS, AccountInfo::empty());
    let wrong = complete_state(&expected).0;
    assert_ne!(wrong, root);
    let mut invalid = block;
    invalid.header.state_root = wrong;
    let invalid =
        reth_primitives_traits::RecoveredBlock::new_unhashed(invalid, vec![SYSTEM_ADDRESS, USER]);
    assert!(matches!(
        crate::stateless::validate_with_closed_prefixes(
            invalid,
            witness,
            config.chain_spec().clone(),
            config,
            &[1]
        ),
        Err(stateless_reth::validation::StatelessValidationError::PostStateRootMismatch { .. })
    ));
}

/// Hydration's counter (`config.hydration`) through the stateless closed-prefix replay:
/// the 0x..0800 slot write must reach the trie, the checkpoint and the terminal root.
#[test]
fn hydration_counter_increment_replays_against_independent_terminal_trie() {
    use hydration_config::COUNTER_ADDRESS;
    let (config, db) = fixture_with_genesis(bytes!("00"), |genesis| {
        genesis.config.extra_fields.insert(
            hydration_config::GENESIS_FIELD.into(),
            serde_json::json!({
                "rulesVersion": 1,
                "oracleUpdater": Address::repeat_byte(0xa1),
                "peplKeeper": Address::repeat_byte(0xb2),
            }),
        );
        genesis.alloc.insert(
            COUNTER_ADDRESS,
            alloy_genesis::GenesisAccount::default().with_nonce(Some(1)),
        );
    });
    assert!(
        db.cache
            .accounts
            .get(&COUNTER_ADDRESS)
            .is_some_and(|info| info.as_ref().is_some_and(|info| info.nonce == 1)),
        "the seeded counter account is part of the pre-state"
    );
    let (pre_root, nodes) = complete_state(&db);
    let mut parent = parent(&config, 5);
    parent.state_root = pre_root;
    let fee = parent
        .next_block_base_fee(eez_protocol::l2::BASE_FEE_PARAMS)
        .unwrap();
    // Intrinsic 21,000 + 4 nonzero calldata bytes at 16, then the counter's 200 base
    // + 2,100 cold SLOAD + 5,000 SSTORE (the EIP-7623 floor, 21,160, is lower).
    let gas_used = 21_000 + 4 * 16 + 200 + 2_100 + 5_000;
    let txs: Vec<EezTxEnvelope> = vec![
        TxLegacy {
            chain_id: Some(901),
            nonce: 0,
            gas_limit: 100_000,
            gas_price: u128::from(fee),
            to: TxKind::Call(COUNTER_ADDRESS),
            input: Bytes::copy_from_slice(&hydration_precompiles::SELECTOR_INCREMENT),
            ..Default::default()
        }
        .into_signed(Signature::new(U256::ONE, U256::ONE, false))
        .into(),
    ];
    let receipts = vec![eez_primitives::Receipt {
        tx_type: eez_primitives::EezTxType::Ethereum(alloy_consensus::TxType::Legacy),
        success: true,
        cumulative_gas_used: gas_used,
        logs: vec![],
    }];
    let mut unwritten = db.clone();
    unwritten.insert_account_storage(
        &alloy_eips::eip2935::HISTORY_STORAGE_ADDRESS,
        &U256::ZERO,
        &U256::from_be_bytes(parent.hash_slow().0),
    );
    let paid = U256::from(fee) * U256::from(gas_used);
    let mut user = unwritten.get_account(&USER).unwrap().unwrap();
    user.nonce = 1;
    user.balance -= paid;
    unwritten.insert_account_info(&USER, user);
    unwritten.insert_account_info(&COLLECTOR, AccountInfo::empty().with_balance(paid));
    for address in [SYSTEM_ADDRESS, EEZL2_ADDRESS] {
        let mut info = unwritten.get_account(&address).unwrap().unwrap();
        info.balance = U256::ZERO;
        unwritten.insert_account_info(&address, info);
    }
    // The seeded nonce 1 is unchanged; slot 0 goes from 0 to 1.
    let mut expected = unwritten.clone();
    expected.insert_account_storage(&COUNTER_ADDRESS, &U256::ZERO, &U256::from(1));
    let root = complete_state(&expected).0;
    let header = Header {
        number: 1,
        timestamp: 5,
        parent_hash: parent.hash_slow(),
        gas_used,
        base_fee_per_gas: Some(fee),
        state_root: root,
        transactions_root: alloy_consensus::proofs::calculate_transaction_root(&txs),
        receipts_root: alloy_consensus::proofs::calculate_receipt_root(
            &receipts
                .iter()
                .map(|r| r.with_bloom_ref())
                .collect::<Vec<_>>(),
        ),
        ..parent.clone()
    };
    let block = eez_primitives::Block::new(
        header,
        alloy_consensus::BlockBody {
            transactions: txs,
            withdrawals: Some(Default::default()),
            ..Default::default()
        },
    );
    let witness = alloy_rpc_types_debug::ExecutionWitness {
        state: nodes,
        codes: db
            .cache
            .contracts
            .values()
            .map(Bytecode::original_bytes)
            .collect(),
        headers: vec![alloy_rlp::encode(&parent).into()],
        ..Default::default()
    };
    let recovered = reth_primitives_traits::RecoveredBlock::new_unhashed(block.clone(), vec![USER]);
    let out = crate::stateless::validate_with_closed_prefixes(
        recovered,
        witness.clone(),
        config.chain_spec().clone(),
        config.clone(),
        &[0],
    )
    .unwrap();
    assert_eq!(out.validation.post_state_root, root);
    assert_eq!(
        out.checkpoints.transaction_state_checkpoints[0].state_root,
        root
    );
    assert_eq!(out.validation.execution_output.result.receipts, receipts);
    // A root without the counter write (gas and fees otherwise identical) is rejected.
    let wrong = complete_state(&unwritten).0;
    assert_ne!(wrong, root);
    let mut invalid = block;
    invalid.header.state_root = wrong;
    let invalid = reth_primitives_traits::RecoveredBlock::new_unhashed(invalid, vec![USER]);
    assert!(matches!(
        crate::stateless::validate_with_closed_prefixes(
            invalid,
            witness,
            config.chain_spec().clone(),
            config,
            &[0]
        ),
        Err(stateless_reth::validation::StatelessValidationError::PostStateRootMismatch { .. })
    ));
}
