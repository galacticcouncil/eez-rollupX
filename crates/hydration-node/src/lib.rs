//! Hydration's protocol-transaction prefix in the EEZ node and signer, switched on
//! by the L2 genesis section `config.hydration` (rules version 1).
//!
//! With the section, a block is `[0x46 history?, oracle update?, keeper?, ...]`:
//! the oracle updater's oracle-update transaction and then the PEPL keeper's
//! transaction directly follow EEZ's optional leading history update. The rule
//! itself lives in the vendored `hydration-consensus-rules` crate (re-exported as
//! [`rules`]); the two role accounts come from the section. EEZ crates hold only
//! the calls into the hooks here:
//!
//! - [`HydrationConsensus`] rejects a misplaced protocol transaction on every
//!   Engine import, for composer and follower alike (both build their consensus
//!   in eez-node-common's `EezConsensusBuilder`);
//! - [`order_pool_transactions`] moves at most one transaction per role ahead of
//!   the pool's own order when the payload builder fills a Live block. The history
//!   update is executed before any pool transaction, so they land right after it;
//! - [`outbound_hold_rejection`] keeps protocol transactions out of the L2
//!   cross-chain front's held transactions (the front still forwards ones it
//!   classifies as ordinary to the L2 mempool). Composer Sync blocks take no
//!   pool transactions; their signed users are held cross-chain transactions
//!   placed after a native load, past the prefix, so a held protocol
//!   transaction would yield a Sync block that [`HydrationConsensus`] rejects;
//! - [`recovered_block_rule_violation`] is the proof signer's check. The signer
//!   replays blocks without the consensus wrapper, so it applies the rule itself
//!   before stateless execution.
//!
//! Without the section every hook is inert: no extra sender recovery, the pool
//! order unchanged and nothing rejected, so the chain runs stock RollupX rules.
//! [`protocol_roles`] is the one reader every hook takes its roles from.

use std::{collections::VecDeque, sync::Arc};

use alloy_consensus::Transaction;
use alloy_primitives::{Address, B256};
pub use hydration_consensus_rules as rules;
pub use hydration_consensus_rules::ProtocolRoles;
use hydration_consensus_rules::{
    BlockTransaction, ProtocolTransaction, classify_protocol_transaction_with_roles,
    first_block_rule_violation_with_roles,
};
use reth_chainspec::EthChainSpec;
use reth_consensus::{
    Consensus, ConsensusError, FullConsensus, HeaderValidator, ReceiptRootBloom, TransactionRoot,
};
use reth_execution_types::BlockExecutionResult;
use reth_primitives_traits::{
    Block, BlockBody as _, BlockHeader, NodePrimitives, RecoveredBlock, SealedBlock, SealedHeader,
};
use reth_transaction_pool::{
    BestTransactions, PoolTransaction, ValidPoolTransaction, error::InvalidPoolTransactionError,
};

/// The protocol roles of `spec`'s `config.hydration` section, or `None` when the
/// section is absent and the chain runs stock rules.
///
/// The section is read through [`eez_evm::profile::hydration`], the reader that
/// installs the counter precompile, so one value switches on every Hydration rule.
///
/// # Errors
///
/// A present section that is malformed or invalid. Callers fail startup on it; it
/// is never treated as absent.
pub fn protocol_roles(
    spec: &impl EthChainSpec<Header = alloy_consensus::Header>,
) -> eyre::Result<Option<ProtocolRoles>> {
    let config = eez_evm::profile::hydration(spec).map_err(eyre::Report::new)?;
    Ok(config.map(|config| ProtocolRoles::new(config.oracle_updater(), config.pepl_keeper())))
}

/// The block index of the first transaction outside its reserved position under
/// `roles`, or `None` when the order is valid or there are no roles.
///
/// `transactions` pairs each transaction, in block order, with its recovered
/// sender (EEZ natives recover to the system address, which holds no role). One
/// leading `0x46` history update is skipped, so the prefix starts after it.
pub fn block_rule_violation<'a, T: Transaction>(
    roles: Option<ProtocolRoles>,
    transactions: impl IntoIterator<Item = (Address, &'a T)>,
) -> Option<usize> {
    first_block_rule_violation_with_roles(
        roles?,
        transactions
            .into_iter()
            .map(|(sender, tx)| BlockTransaction {
                tx_type: tx.ty(),
                sender,
                input: tx.input(),
            }),
    )
}

/// [`block_rule_violation`] over a block whose senders are already recovered.
pub fn recovered_block_rule_violation<B: Block>(
    roles: Option<ProtocolRoles>,
    block: &RecoveredBlock<B>,
) -> Option<usize> {
    block_rule_violation(
        roles,
        block
            .senders_iter()
            .copied()
            .zip(block.body().transactions()),
    )
}

/// Why a cross-chain front must refuse to hold an L2-source (outbound)
/// transaction from `sender` with calldata `input`, or `None` to continue
/// admission. Always `None` without roles.
///
/// Only a transaction the rule classifies as a protocol transaction is refused:
/// the oracle updater's oracle updates and every keeper transaction. Its only
/// valid position is the prefix of a Live block, which the payload builder fills
/// from the L2 mempool.
pub fn outbound_hold_rejection(
    roles: Option<ProtocolRoles>,
    sender: Address,
    input: &[u8],
) -> Option<String> {
    let kind = match classify_protocol_transaction_with_roles(roles?, sender, input) {
        ProtocolTransaction::Ordinary => return None,
        ProtocolTransaction::OracleUpdate => "oracle update",
        ProtocolTransaction::Pepl => "PEPL keeper transaction",
    };
    Some(format!(
        "Hydration {kind} from {sender} must use the L2 mempool, not a cross-chain front: a Sync block cannot place it in the protocol prefix"
    ))
}

/// Delegates every check to `inner`, then, when the chain has Hydration roles,
/// rejects a block whose protocol transactions are outside their prefix.
#[derive(Debug, Clone)]
pub struct HydrationConsensus<C> {
    inner: C,
    roles: Option<ProtocolRoles>,
}

impl<C> HydrationConsensus<C> {
    /// `inner` plus the prefix rule for `roles`; with `None`, `inner` alone.
    pub const fn new(inner: C, roles: Option<ProtocolRoles>) -> Self {
        Self { inner, roles }
    }

    /// `inner` plus the prefix rule of `spec`'s `config.hydration`, if any.
    ///
    /// # Errors
    ///
    /// As [`protocol_roles`].
    pub fn for_chain(
        inner: C,
        spec: &impl EthChainSpec<Header = alloy_consensus::Header>,
    ) -> eyre::Result<Self> {
        Ok(Self::new(inner, protocol_roles(spec)?))
    }

    /// The roles this wrapper enforces; `None` when it only delegates.
    pub const fn roles(&self) -> Option<ProtocolRoles> {
        self.roles
    }

    fn validate_protocol_prefix<B: Block>(
        &self,
        block: &SealedBlock<B>,
    ) -> Result<(), ConsensusError> {
        let Some(roles) = self.roles else {
            return Ok(());
        };
        // Pre-execution validation sees an unrecovered block. Native 0x45/0x46
        // transactions recover to EEZ's system address, which holds no role.
        let senders = block
            .body()
            .try_recover_signers()
            .map_err(|_| ConsensusError::TransactionSignerRecoveryError)?;
        if let Some(index) = block_rule_violation(
            Some(roles),
            senders.into_iter().zip(block.body().transactions()),
        ) {
            return Err(ConsensusError::msg(format!(
                "invalid protocol transaction position at block index {index}"
            )));
        }
        Ok(())
    }
}

impl<H: BlockHeader, C: HeaderValidator<H>> HeaderValidator<H> for HydrationConsensus<C> {
    fn validate_header(&self, header: &SealedHeader<H>) -> Result<(), ConsensusError> {
        self.inner.validate_header(header)
    }

    fn validate_header_against_parent(
        &self,
        header: &SealedHeader<H>,
        parent: &SealedHeader<H>,
    ) -> Result<(), ConsensusError> {
        self.inner.validate_header_against_parent(header, parent)
    }
}

impl<B: Block, C: Consensus<B>> Consensus<B> for HydrationConsensus<C> {
    fn validate_body_against_header(
        &self,
        body: &B::Body,
        header: &SealedHeader<B::Header>,
    ) -> Result<(), ConsensusError> {
        self.inner.validate_body_against_header(body, header)
    }

    fn validate_block_pre_execution(&self, block: &SealedBlock<B>) -> Result<(), ConsensusError> {
        self.inner.validate_block_pre_execution(block)?;
        self.validate_protocol_prefix(block)
    }

    fn is_transient_error(&self, error: &ConsensusError) -> bool {
        self.inner.is_transient_error(error)
    }

    // The Engine calls this form (reth-engine-tree payload_validator).
    fn validate_block_pre_execution_with_tx_root(
        &self,
        block: &SealedBlock<B>,
        transaction_root: Option<TransactionRoot>,
    ) -> Result<(), ConsensusError> {
        self.inner
            .validate_block_pre_execution_with_tx_root(block, transaction_root)?;
        self.validate_protocol_prefix(block)
    }
}

impl<N: NodePrimitives, C: FullConsensus<N>> FullConsensus<N> for HydrationConsensus<C> {
    fn validate_block_post_execution(
        &self,
        block: &RecoveredBlock<N::Block>,
        result: &BlockExecutionResult<N::Receipt>,
        receipt_root_bloom: Option<ReceiptRootBloom>,
        block_access_list_hash: Option<B256>,
    ) -> Result<(), ConsensusError> {
        self.inner.validate_block_post_execution(
            block,
            result,
            receipt_root_bloom,
            block_access_list_hash,
        )
    }
}

/// The payload builder's candidate iterator over pool transactions.
pub type PoolTransactions<T> = Box<dyn BestTransactions<Item = Arc<ValidPoolTransaction<T>>>>;

/// The pool's best transactions for a Live block. With `roles`, the first oracle
/// update and the first keeper transaction it yields go ahead of the rest, in that
/// order; without, `best` is returned unchanged.
///
/// Apply this before any filter that may skip transactions (the DA budget): a
/// skipped oracle update leaves a lone keeper transaction, which the rule allows.
pub fn order_pool_transactions<T: PoolTransaction>(
    roles: Option<ProtocolRoles>,
    best: PoolTransactions<T>,
) -> PoolTransactions<T> {
    let Some(roles) = roles else {
        return best;
    };
    Box::new(ProtocolPrefix::new(
        best,
        move |tx: &Arc<ValidPoolTransaction<T>>| {
            classify_protocol_transaction_with_roles(roles, tx.sender(), tx.transaction.input())
        },
    ))
}

/// Yields at most one transaction per protocol role ahead of everything else.
///
/// Ported from eez-rollup0's payload builder. On the first `next` it drains `inner`
/// and buffers its order; later protocol transactions of either role are dropped
/// from this build (they stay in the pool). Transactions that reach `inner` after
/// the drain are not seen. `mark_invalid` reaches `inner` only, so buffered
/// descendants of a rejected transaction are still yielded; the builder then skips
/// them on their nonce error. That costs O(pool) per build and some failed
/// executions, never an invalid block.
struct ProtocolPrefix<I: Iterator, F> {
    inner: I,
    classify: F,
    oracle: Option<I::Item>,
    keeper: Option<I::Item>,
    ordinary: VecDeque<I::Item>,
    drained: bool,
}

impl<I: Iterator, F> ProtocolPrefix<I, F> {
    fn new(inner: I, classify: F) -> Self {
        Self {
            inner,
            classify,
            oracle: None,
            keeper: None,
            ordinary: VecDeque::new(),
            drained: false,
        }
    }
}

impl<I: Iterator, F: Fn(&I::Item) -> ProtocolTransaction> Iterator for ProtocolPrefix<I, F> {
    type Item = I::Item;

    fn next(&mut self) -> Option<Self::Item> {
        if !self.drained {
            for item in self.inner.by_ref() {
                match (self.classify)(&item) {
                    ProtocolTransaction::OracleUpdate if self.oracle.is_none() => {
                        self.oracle = Some(item);
                    }
                    ProtocolTransaction::Pepl if self.keeper.is_none() => self.keeper = Some(item),
                    ProtocolTransaction::Ordinary => self.ordinary.push_back(item),
                    ProtocolTransaction::OracleUpdate | ProtocolTransaction::Pepl => {}
                }
            }
            self.drained = true;
        }
        self.oracle
            .take()
            .or_else(|| self.keeper.take())
            .or_else(|| self.ordinary.pop_front())
    }
}

impl<I, F> BestTransactions for ProtocolPrefix<I, F>
where
    I: BestTransactions<Item: Send>,
    F: Fn(&I::Item) -> ProtocolTransaction + Send,
{
    fn mark_invalid(&mut self, tx: &Self::Item, kind: InvalidPoolTransactionError) {
        self.inner.mark_invalid(tx, kind);
    }

    fn no_updates(&mut self) {
        self.inner.no_updates();
    }

    fn allow_updates_out_of_order(&mut self) {
        self.inner.allow_updates_out_of_order();
    }

    fn set_skip_blobs(&mut self, skip_blobs: bool) {
        self.inner.set_skip_blobs(skip_blobs);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_consensus::{
        Header, SignableTransaction as _, TxLegacy, Typed2718 as _,
        transaction::SignerRecoverable as _,
    };
    use alloy_primitives::{Bytes, Signature, TxKind, U256, address};
    use eez_primitives::{EezTxEnvelope, HistoryBlock, HistoryTransaction, SYSTEM_ADDRESS};
    use hydration_config::{COUNTER_ADDRESS, GENESIS_FIELD};
    use reth_chainspec::ChainSpec;
    use reth_consensus::noop::NoopConsensus;
    use rules::{ORACLE_UPDATE_SELECTOR, ORACLE_UPDATER_ADDRESS, PEPL_KEEPER_ADDRESS};

    const ORACLE: Address = address!("00000000000000000000000000000000000000a1");
    const KEEPER: Address = address!("00000000000000000000000000000000000000b2");

    /// The repository's L2 genesis, plus the section and its alloc seed if given.
    /// Built with `ChainSpec::from_genesis`, not `profile::chain_spec`, so the
    /// readers here must reject a bad section on their own.
    fn spec(section: Option<serde_json::Value>) -> ChainSpec {
        let mut genesis: alloy_genesis::Genesis =
            serde_json::from_slice(include_bytes!("../../../genesis.json")).unwrap();
        if let Some(section) = section {
            genesis
                .config
                .extra_fields
                .insert(GENESIS_FIELD.into(), section);
            genesis.alloc.insert(
                COUNTER_ADDRESS,
                alloy_genesis::GenesisAccount::default().with_nonce(Some(1)),
            );
        }
        ChainSpec::from_genesis(genesis)
    }

    fn section(oracle: Address, keeper: Address) -> serde_json::Value {
        serde_json::json!({ "rulesVersion": 1, "oracleUpdater": oracle, "peplKeeper": keeper })
    }

    #[test]
    fn roles_come_from_the_section_and_a_bad_section_fails_startup() {
        assert_eq!(protocol_roles(&spec(None)).unwrap(), None);
        assert_eq!(
            protocol_roles(&spec(Some(section(ORACLE, KEEPER)))).unwrap(),
            Some(ProtocolRoles::new(ORACLE, KEEPER))
        );
        for (bad, reason) in [
            (
                section(Address::ZERO, KEEPER),
                "config.hydration oracleUpdater is the zero address",
            ),
            (
                section(ORACLE, ORACLE),
                "config.hydration oracleUpdater and peplKeeper are the same account",
            ),
            (
                section(ORACLE, SYSTEM_ADDRESS),
                "config.hydration oracleUpdater or peplKeeper is the EEZ system address",
            ),
            (serde_json::Value::Null, "malformed config.hydration"),
        ] {
            let spec = spec(Some(bad));
            let error = protocol_roles(&spec).unwrap_err().to_string();
            assert!(error.contains(reason), "{error}");
            let error = HydrationConsensus::for_chain(NoopConsensus::default(), &spec)
                .unwrap_err()
                .to_string();
            assert!(error.contains(reason), "{error}");
        }
    }

    fn sealed(transactions: Vec<EezTxEnvelope>) -> SealedBlock<eez_primitives::Block> {
        SealedBlock::seal_slow(eez_primitives::Block::new(
            Header::default(),
            alloy_consensus::BlockBody {
                transactions,
                ..Default::default()
            },
        ))
    }

    #[test]
    fn without_the_section_the_wrapper_only_delegates() {
        // An unrecoverable signature: only the rule's own sender recovery can fail.
        let unrecoverable: EezTxEnvelope = TxLegacy {
            to: TxKind::Call(Address::ZERO),
            ..Default::default()
        }
        .into_signed(Signature::new(U256::ZERO, U256::ZERO, false))
        .into();
        assert!(unrecoverable.recover_signer().is_err());
        let block = sealed(vec![unrecoverable]);

        let stock = HydrationConsensus::for_chain(NoopConsensus::default(), &spec(None)).unwrap();
        assert_eq!(stock.roles(), None);
        stock.validate_block_pre_execution(&block).unwrap();
        stock
            .validate_block_pre_execution_with_tx_root(&block, None)
            .unwrap();

        let hydration = HydrationConsensus::for_chain(
            NoopConsensus::default(),
            &spec(Some(section(ORACLE, KEEPER))),
        )
        .unwrap();
        assert_eq!(hydration.roles(), Some(ProtocolRoles::new(ORACLE, KEEPER)));
        for result in [
            hydration.validate_block_pre_execution(&block),
            hydration.validate_block_pre_execution_with_tx_root(&block, None),
        ] {
            assert!(
                matches!(result, Err(ConsensusError::TransactionSignerRecoveryError)),
                "{result:?}"
            );
        }
    }

    #[test]
    fn natives_recover_to_the_system_address_which_holds_no_role() {
        let history: EezTxEnvelope = HistoryTransaction {
            version: 1,
            chain_id: 1,
            blocks: vec![HistoryBlock {
                number: 1,
                block_hash: B256::repeat_byte(1),
            }],
        }
        .into();
        assert_eq!(history.ty(), hydration_consensus_rules::EEZ_HISTORY_TX_TYPE);
        assert_eq!(history.recover_signer().unwrap(), SYSTEM_ADDRESS);
        assert_eq!(
            classify_protocol_transaction_with_roles(
                ProtocolRoles::new(ORACLE, KEEPER),
                SYSTEM_ADDRESS,
                &[]
            ),
            ProtocolTransaction::Ordinary
        );
    }

    #[test]
    fn prefix_iterator_moves_one_transaction_per_role_ahead_in_role_order() {
        let ordered: Vec<u8> = ProtocolPrefix::new(
            [1u8, 9, 2, 7, 3, 7, 9].into_iter(),
            |item: &u8| match item {
                7 => ProtocolTransaction::OracleUpdate,
                9 => ProtocolTransaction::Pepl,
                _ => ProtocolTransaction::Ordinary,
            },
        )
        .collect();
        assert_eq!(ordered, vec![7, 9, 1, 2, 3]);
    }

    fn call(input: &'static [u8]) -> EezTxEnvelope {
        TxLegacy {
            to: TxKind::Call(Address::ZERO),
            input: Bytes::from_static(input),
            ..Default::default()
        }
        .into_signed(Signature::test_signature())
        .into()
    }

    #[test]
    fn recovered_block_check_skips_one_history_update_and_is_inert_without_roles() {
        let roles = Some(ProtocolRoles::new(ORACLE, KEEPER));
        let history: EezTxEnvelope = HistoryTransaction {
            version: 1,
            chain_id: 1,
            blocks: vec![HistoryBlock {
                number: 1,
                block_hash: B256::repeat_byte(1),
            }],
        }
        .into();
        let user = Address::repeat_byte(0x33);
        let block = |transactions: Vec<(EezTxEnvelope, Address)>| {
            let (transactions, senders): (Vec<_>, Vec<_>) = transactions.into_iter().unzip();
            RecoveredBlock::new_unhashed(
                eez_primitives::Block::new(
                    Header::default(),
                    alloy_consensus::BlockBody {
                        transactions,
                        ..Default::default()
                    },
                ),
                senders,
            )
        };
        let oracle = || (call(&ORACLE_UPDATE_SELECTOR), ORACLE);
        let keeper = || (call(&[]), KEEPER);
        let ordinary = || (call(&[0xde, 0xad]), user);

        let valid = block(vec![
            (history.clone(), SYSTEM_ADDRESS),
            oracle(),
            keeper(),
            ordinary(),
        ]);
        assert_eq!(recovered_block_rule_violation(roles, &valid), None);
        // The history update is skipped once: the keeper after an ordinary
        // transaction is misplaced at its absolute index.
        let late_keeper = block(vec![(history, SYSTEM_ADDRESS), ordinary(), keeper()]);
        assert_eq!(recovered_block_rule_violation(roles, &late_keeper), Some(2));
        let late_oracle = block(vec![ordinary(), oracle()]);
        assert_eq!(recovered_block_rule_violation(roles, &late_oracle), Some(1));
        for stock in [&late_keeper, &late_oracle] {
            assert_eq!(recovered_block_rule_violation(None, stock), None);
        }
        // The oracle updater's other calls are ordinary.
        let oracle_transfer = block(vec![ordinary(), (call(&[0xde, 0xad]), ORACLE)]);
        assert_eq!(
            recovered_block_rule_violation(roles, &oracle_transfer),
            None
        );
    }

    #[test]
    fn outbound_hold_rejection_refuses_only_configured_protocol_transactions() {
        let roles = Some(ProtocolRoles::new(ORACLE, KEEPER));
        for (sender, input, kind) in [
            (ORACLE, &ORACLE_UPDATE_SELECTOR[..], "oracle update"),
            (KEEPER, &[][..], "PEPL keeper transaction"),
            (KEEPER, &[0xde, 0xad][..], "PEPL keeper transaction"),
        ] {
            let reason = outbound_hold_rejection(roles, sender, input).unwrap();
            assert!(reason.contains(kind), "{reason}");
            assert!(reason.contains("must use the L2 mempool"), "{reason}");
            assert_eq!(outbound_hold_rejection(None, sender, input), None);
        }
        for (sender, input) in [
            (ORACLE, &[0xde, 0xad][..]),
            (Address::repeat_byte(0x33), &ORACLE_UPDATE_SELECTOR[..]),
            // The compiled-in development roles hold nothing on this chain.
            (ORACLE_UPDATER_ADDRESS, &ORACLE_UPDATE_SELECTOR[..]),
            (PEPL_KEEPER_ADDRESS, &[][..]),
        ] {
            assert_eq!(outbound_hold_rejection(roles, sender, input), None);
        }
    }
}
