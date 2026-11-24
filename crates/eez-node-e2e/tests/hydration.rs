//! Hydration's rules on a running network: the L2 genesis carries
//! `config.hydration` (see `setup_cross_chain_with_hydration`), so the Composer
//! node and the proof signer both run the counter precompile and the
//! protocol-transaction prefix.
//!
//! - `l1_call_increments_the_counter_precompile`: an L1 user calls the counter
//!   at `0x…0800` through its L1 `CrossChainProxy`. Composer simulates the
//!   delivery, packs it into a Sync block, the signer re-executes it and the
//!   batch settles.
//! - `counter_precompile_drives_an_outbound_call`: one L2 transaction bumps the
//!   counter and pushes the returned count to an L1 `Value`, then decodes L1's
//!   answer in the same frame. The L1 calldata comes from precompile state,
//!   so this holds only if Composer's L2 simulation runs Hydration's rules.
//! - `oracle_and_keeper_lead_their_block_then_settle`: an oracle update and a
//!   keeper transaction move ahead of an earlier, higher-fee ordinary
//!   transaction into the block's protocol prefix, and the block settles.
//!
//! A stock EVM anywhere in the pipeline would see `0x…0800` as an empty
//! account, and a component without the prefix rule would disagree on the
//! ordered block; either breaks settlement or the state assertions below.

use std::time::Duration;

use alloy_consensus::{SignableTransaction, TxEip1559, TxEnvelope};
use alloy_network::{TxSignerSync, eip2718::Encodable2718};
use alloy_primitives::{B256, Bytes, TxHash, U256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_rpc_types_eth::{AccessList, TransactionReceipt};
use alloy_signer_local::PrivateKeySigner;
use alloy_sol_types::SolCall;

use eez_testkit::{
    ANVIL_ADDR_3, ANVIL_ATTESTER_KEY, CrossChainWorld, DEV_CHAIN_ID, ICounterRelay, INBOUND_USER,
    IValue, SETTLE_TIMEOUT, Scenario, ScenarioCall, TARGET_DEPLOYER, assert_latest_batch_signature,
    batches_posted, call_read, create_cross_chain_proxy, deploy_counter_relay, onchain_nonce,
    receipt_ok, safe_block_hash, setup_cross_chain_with_hydration, sign_and_send, signer_address,
    state_root, value_read, wait_for, wait_for_safe_chain_contains,
};
use hydration_config::COUNTER_ADDRESS;
use hydration_consensus_rules::ORACLE_UPDATE_SELECTOR;
use hydration_precompiles::{COUNTER_SLOT, SELECTOR_INCREMENT};

/// Anvil development accounts 7 and 8 hold the two roles. Both are funded in
/// the fixture genesis and send nothing else in the fixture, and neither is a
/// legacy (compiled-in) Hydreth role, so these tests also show that the roles
/// come from genesis.
const ORACLE_KEY: &str = "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356";
const KEEPER_KEY: &str = "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97";
/// Anvil development account 9: an ordinary L2 sender for the ordering test.
const ORDINARY_KEY: &str = "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";

const MAX_FEE_PER_GAS: u128 = 100_000_000_000;
const PROTOCOL_PRIORITY_FEE: u128 = 1;
const ORDINARY_PRIORITY_FEE: u128 = 10_000_000_000;
const INCLUSION_TIMEOUT: Duration = Duration::from_mins(2);

async fn hydration_world(extra_env: &[(&'static str, String)]) -> CrossChainWorld {
    setup_cross_chain_with_hydration(
        signer_address(ORACLE_KEY).unwrap(),
        signer_address(KEEPER_KEY).unwrap(),
        extra_env,
    )
    .await
    .unwrap()
}

/// The counter's storage slot read from the L2 trie at `block` (latest when
/// `None`), so the precompile must actually have written state.
async fn counter_slot(l2_rpc: &str, block: Option<B256>) -> anyhow::Result<U256> {
    let provider = ProviderBuilder::new().connect_http(l2_rpc.parse()?);
    let read = provider.get_storage_at(COUNTER_ADDRESS, COUNTER_SLOT);
    Ok(match block {
        Some(hash) => read.block_id(hash.into()).await?,
        None => read.await?,
    })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn l1_call_increments_the_counter_precompile() {
    let attester = signer_address(ANVIL_ATTESTER_KEY).unwrap();
    let w = hydration_world(&[]).await;
    let (l1_rpc, l2_rpc) = (w.l1_rpc(), w.l2_rpc());
    let (eez, rollup_id) = (w.cfg.eez_address, w.cfg.rollup_id);

    assert_eq!(
        counter_slot(&l2_rpc, None).await.unwrap(),
        U256::ZERO,
        "fresh chain: the counter slot starts at zero"
    );

    // The L1 face of the L2 precompile.
    let counter_proxy =
        create_cross_chain_proxy(&l1_rpc, INBOUND_USER, eez, COUNTER_ADDRESS, rollup_id)
            .await
            .expect("create the L1 proxy for 0x…0800");
    let inbound = sign_and_send(
        &w.l1_xchain(),
        INBOUND_USER,
        DEV_CHAIN_ID,
        onchain_nonce(&l1_rpc, INBOUND_USER).await.unwrap(),
        Some(counter_proxy),
        U256::ZERO,
        SELECTOR_INCREMENT.to_vec(),
        600_000,
    )
    .await
    .expect("the L1 front must admit increment() through the proxy");

    let status = wait_for(SETTLE_TIMEOUT, || {
        let l1 = l1_rpc.clone();
        async move { receipt_ok(&l1, inbound).await }
    })
    .await
    .unwrap_or_else(|err| {
        panic!(
            "increment() via the proxy did not land on L1: {err:#}{}",
            w.settlement_diagnostics()
        )
    });
    assert!(status, "increment() via the proxy reverted on L1");

    // Settled means the L1 commitment is the L2 safe block, and that block's
    // own state holds the increment.
    let settled = wait_for(SETTLE_TIMEOUT, || {
        let (l1, l2) = (l1_rpc.clone(), l2_rpc.clone());
        async move {
            let committed = state_root(&l1, eez, rollup_id).await?;
            let Some(safe) = safe_block_hash(&l2).await? else {
                return Ok(None);
            };
            let slot = counter_slot(&l2, Some(safe)).await?;
            Ok((safe == committed && slot == U256::from(1)).then_some(()))
        }
    })
    .await;
    if let Err(err) = settled {
        panic!(
            "the counter increment did not settle (latest slot {:?}): {err:#}{}",
            counter_slot(&l2_rpc, None).await,
            w.settlement_diagnostics()
        );
    }

    assert!(
        batches_posted(&l1_rpc, eez, w.dep.deploy_block)
            .await
            .unwrap()
            >= 1,
        "at least one batch must be posted"
    );
    assert_latest_batch_signature(&l1_rpc, &w.dep, attester)
        .await
        .expect("the posted proof must recover over the recomputed public-input hash");
    assert_eq!(
        w.node.log_count_matching(&["evicting"]).unwrap(),
        0,
        "the precompile call must not be evicted"
    );
    w.node.assert_no_divergence_failure_logs();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn counter_precompile_drives_an_outbound_call() {
    let w = hydration_world(&[]).await;
    let l2_rpc = w.l2_rpc();
    let l1 = ProviderBuilder::new().connect_http(w.l1_rpc().parse().unwrap());
    let l2 = ProviderBuilder::new().connect_http(l2_rpc.parse().unwrap());

    assert_eq!(
        counter_slot(&l2_rpc, None).await.unwrap(),
        U256::ZERO,
        "fresh chain: the counter slot starts at zero"
    );
    // The fixture's L1 `Value` starts at 5, so pushing the first count (1)
    // must report `changed`.
    assert_eq!(
        IValue::new(w.outbound_value, &l1)
            .value()
            .call()
            .await
            .unwrap(),
        U256::from(5)
    );

    let relay = deploy_counter_relay(
        &l2_rpc,
        TARGET_DEPLOYER,
        w.l2_chain_id,
        w.outbound_proxy,
        &w.node,
    )
    .await
    .expect("deploy CounterRelay on the L2");

    // One L2 transaction: counter bump, cross-chain push, return decode.
    Scenario::new("Hydration counter precompile drives an outbound call")
        .outbound(
            ScenarioCall::new(relay, ICounterRelay::bumpAndRelayCall {}.abi_encode())
                .with_gas_limit(900_000),
        )
        .expect_l1_state(value_read(w.outbound_value), 1_u64)
        .expect_l2_state(
            call_read(relay, "relayed", ICounterRelay::relayedCall {}.abi_encode()),
            1_u64,
        )
        .expect_l2_state(
            call_read(
                relay,
                "lastCount",
                ICounterRelay::lastCountCall {}.abi_encode(),
            ),
            1_u64,
        )
        .expect_settled_fully()
        .run(&w)
        .await
        .unwrap();

    assert_eq!(
        counter_slot(&l2_rpc, None).await.unwrap(),
        U256::from(1),
        "the counter precompile must have written its slot on the L2"
    );
    // L1's `(changed, newValue)` came back into the L2 frame: a synchronous
    // call, not a fire-and-forget message.
    assert!(
        ICounterRelay::new(relay, &l2)
            .lastChanged()
            .call()
            .await
            .unwrap(),
        "L1 return data must be decoded back into the L2 frame"
    );
}

fn signed_call(
    key: &str,
    chain_id: u64,
    nonce: u64,
    input: Bytes,
    priority_fee: u128,
) -> (TxHash, Vec<u8>) {
    let signer: PrivateKeySigner = key
        .strip_prefix("0x")
        .unwrap_or(key)
        .parse()
        .expect("parse test signing key");
    let mut tx = TxEip1559 {
        chain_id,
        nonce,
        gas_limit: 50_000,
        max_fee_per_gas: MAX_FEE_PER_GAS,
        max_priority_fee_per_gas: priority_fee,
        to: alloy_primitives::TxKind::Call(ANVIL_ADDR_3),
        value: U256::ZERO,
        access_list: AccessList::default(),
        input,
    };
    let signature = signer
        .sign_transaction_sync(&mut tx)
        .expect("sign L2 transaction");
    let envelope = TxEnvelope::from(tx.into_signed(signature));
    (*envelope.tx_hash(), envelope.encoded_2718())
}

async fn pending_nonce<P: Provider>(provider: &P, key: &str) -> u64 {
    provider
        .get_transaction_count(signer_address(key).unwrap())
        .pending()
        .await
        .unwrap()
}

async fn wait_for_receipt<P: Provider>(provider: &P, hash: TxHash) -> TransactionReceipt {
    wait_for(INCLUSION_TIMEOUT, || async {
        Ok(provider.get_transaction_receipt(hash).await?)
    })
    .await
    .unwrap_or_else(|err| panic!("transaction {hash} was not included: {err:#}"))
}

/// The block's protocol prefix starts after EEZ's optional leading `0x46`
/// history update, which the prefix rule skips.
async fn prefix_start<P: Provider>(provider: &P, block: B256) -> u64 {
    let block: serde_json::Value = provider
        .client()
        .request("eth_getBlockByHash", (block, true))
        .await
        .unwrap();
    let history = format!("0x{:x}", eez_primitives::HISTORY_TX_TYPE);
    u64::from(block["transactions"][0]["type"] == history)
}

/// The prefix rule beats both arrival order and fees, and the ordered block
/// is accepted by consensus, the proof signer and L1 settlement.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn oracle_and_keeper_lead_their_block_then_settle() {
    // The ordered block holds only ordinary L2 transactions, which the shared
    // fixture otherwise settles once a day (`EEZ_SETTLEMENT_PURE_L2_INTERVAL_MS`).
    let w = hydration_world(&[("EEZ_SETTLEMENT_PURE_L2_MODE", "always".into())]).await;
    let provider = ProviderBuilder::new().connect_http(w.l2_rpc().parse().unwrap());
    let chain_id = w.l2_chain_id;

    let (ordinary_hash, ordinary_raw) = signed_call(
        ORDINARY_KEY,
        chain_id,
        pending_nonce(&provider, ORDINARY_KEY).await,
        Bytes::from_static(&[0xde, 0xad, 0xbe, 0xef]),
        ORDINARY_PRIORITY_FEE,
    );
    let (keeper_hash, keeper_raw) = signed_call(
        KEEPER_KEY,
        chain_id,
        pending_nonce(&provider, KEEPER_KEY).await,
        Bytes::new(),
        PROTOCOL_PRIORITY_FEE,
    );
    let (oracle_hash, oracle_raw) = signed_call(
        ORACLE_KEY,
        chain_id,
        pending_nonce(&provider, ORACLE_KEY).await,
        Bytes::copy_from_slice(&ORACLE_UPDATE_SELECTOR),
        PROTOCOL_PRIORITY_FEE,
    );

    // Start just after a block boundary so all three share the next block, and
    // submit in the reverse of the required order. The ordinary transaction
    // also pays the highest tip.
    let before = provider.get_block_number().await.unwrap();
    wait_for(INCLUSION_TIMEOUT, || async {
        let height = provider.get_block_number().await?;
        Ok((height > before).then_some(()))
    })
    .await
    .expect("the L2 did not advance before submission");
    for (raw, hash) in [
        (&ordinary_raw, ordinary_hash),
        (&keeper_raw, keeper_hash),
        (&oracle_raw, oracle_hash),
    ] {
        assert_eq!(
            *provider.send_raw_transaction(raw).await.unwrap().tx_hash(),
            hash
        );
    }

    let (oracle, keeper, ordinary) = tokio::join!(
        wait_for_receipt(&provider, oracle_hash),
        wait_for_receipt(&provider, keeper_hash),
        wait_for_receipt(&provider, ordinary_hash),
    );
    for receipt in [&oracle, &keeper, &ordinary] {
        assert!(
            receipt.status(),
            "transaction {} reverted",
            receipt.transaction_hash
        );
    }
    let block_number = oracle.block_number.unwrap();
    let block_hash = oracle.block_hash.unwrap();
    assert_eq!(
        keeper.block_hash,
        Some(block_hash),
        "keeper in another block"
    );
    assert_eq!(
        ordinary.block_hash,
        Some(block_hash),
        "ordinary in another block"
    );

    let start = prefix_start(&provider, block_hash).await;
    assert_eq!(oracle.transaction_index, Some(start), "oracle update leads");
    assert_eq!(
        keeper.transaction_index,
        Some(start + 1),
        "the keeper follows the oracle update"
    );
    assert!(
        ordinary.transaction_index > keeper.transaction_index,
        "ordinary transactions follow the protocol prefix"
    );

    wait_for_safe_chain_contains(&w.node, block_number, block_hash, SETTLE_TIMEOUT)
        .await
        .unwrap_or_else(|err| {
            panic!(
                "the ordered block did not settle: {err:#}{}",
                w.settlement_diagnostics()
            )
        });
    assert!(
        batches_posted(&w.l1_rpc(), w.cfg.eez_address, w.dep.deploy_block)
            .await
            .unwrap()
            >= 1
    );
    w.node.assert_no_divergence_failure_logs();
}
