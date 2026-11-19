//! Portable consensus rules for Hydration protocol transactions.
//!
//! This crate deliberately has no Reth, revm, or EVM configuration dependency.
//! Nodes and proving guests can therefore share the protocol rule while keeping
//! their execution stacks independently pinned.
//!
//! A block may begin with a reserved protocol prefix. The current prefix has
//! two roles: an authenticated oracle update followed by an optional keeper
//! transaction. Transactions with either role are invalid outside their
//! reserved positions; all other transactions are ordinary.
//!
//! On an EEZ rollupX chain the host may place its native L1-history update
//! (EIP-2718 type [`EEZ_HISTORY_TX_TYPE`]) at transaction zero. That one
//! transaction is skipped: the Hydration prefix then starts at index one.
//! Nothing else is skipped. In particular an EEZ cross-chain `0x45`
//! transaction is ordinary here, so a protocol transaction carried as the
//! signed user transaction of an outbound group is misplaced.
//!
//! Which accounts hold the two roles is a [`ProtocolRoles`] value. The
//! role-free functions use [`ProtocolRoles::LEGACY`], the roles compiled into
//! Hydreth, its ZisK guest and eez-rollup0. A chain that fixes its own roles
//! at genesis (EEZ rollupX) passes them to the `*_with_roles` functions or to
//! [`ProtocolPrefixCursor::with_roles`].

#![cfg_attr(not(feature = "std"), no_std)]

use alloy_primitives::{Address, address};

/// Dedicated protocol account whose transactions have the keeper role.
///
/// This is the third account derived by the development mnemonic, and the
/// keeper of [`ProtocolRoles::LEGACY`]. Hydreth compiles it in, rather than
/// reading node configuration, because every validator and proving guest must
/// classify the same transactions identically.
pub const PEPL_KEEPER_ADDRESS: Address = address!("3c44cdddb6a900fa2b585dd299e03d12fa4293bc");

/// Authorized account whose supported price-setting calls are oracle updates.
///
/// The fixture uses the first account derived by the development mnemonic; it
/// is the oracle updater of [`ProtocolRoles::LEGACY`]. A production chain
/// should assign this role to its protocol oracle authority.
pub const ORACLE_UPDATER_ADDRESS: Address = address!("f39fd6e51aad88f6f4ce6ab8827279cfffb92266");

/// ABI selector for `setAssetPrice(address,uint256)`.
pub const ORACLE_UPDATE_SELECTOR: [u8; 4] = [0x51, 0x32, 0x3f, 0x72];
/// ABI selector for `setAssetPrices(address[],uint256[])`.
pub const ORACLE_BATCH_UPDATE_SELECTOR: [u8; 4] = [0xec, 0xb1, 0xc8, 0x5a];

/// EIP-2718 type of EEZ rollupX's native L1-history update.
///
/// EEZ's own executor admits it only as transaction zero. Ethereum-typed
/// chains (Hydreth, eez-rollup0) cannot decode this type, so on them the
/// skip below never applies.
pub const EEZ_HISTORY_TX_TYPE: u8 = 0x46;

/// Consensus-relevant role of a signed Ethereum transaction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtocolTransaction {
    /// An ordinary transaction with no reserved block position.
    Ordinary,
    /// An authenticated oracle price update.
    OracleUpdate,
    /// A transaction signed by the dedicated protocol keeper.
    Pepl,
}

/// Accounts holding the two protocol roles on one chain.
///
/// Every validator and proving guest of a chain must classify with the same
/// roles, so they are consensus parameters fixed for the chain (compiled in,
/// or read from its genesis), never per-node configuration.
///
/// The keeper is checked first: if both fields hold the same address, every
/// transaction from it is a keeper transaction and none is an oracle update.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ProtocolRoles {
    /// Account whose supported price-setting calls are oracle updates.
    pub oracle_updater: Address,
    /// Account whose every transaction is a keeper transaction.
    pub pepl_keeper: Address,
}

impl ProtocolRoles {
    /// The roles compiled into Hydreth, its ZisK guest and eez-rollup0:
    /// [`ORACLE_UPDATER_ADDRESS`] and [`PEPL_KEEPER_ADDRESS`], both accounts of
    /// the public development mnemonic.
    pub const LEGACY: Self = Self::new(ORACLE_UPDATER_ADDRESS, PEPL_KEEPER_ADDRESS);

    /// Roles held by the given accounts.
    pub const fn new(oracle_updater: Address, pepl_keeper: Address) -> Self {
        Self {
            oracle_updater,
            pepl_keeper,
        }
    }
}

/// Classifies a transaction by its sender and calldata under `roles`.
pub fn classify_protocol_transaction_with_roles(
    roles: ProtocolRoles,
    sender: Address,
    input: &[u8],
) -> ProtocolTransaction {
    if sender == roles.pepl_keeper {
        ProtocolTransaction::Pepl
    } else if sender == roles.oracle_updater
        && (input.starts_with(&ORACLE_UPDATE_SELECTOR)
            || input.starts_with(&ORACLE_BATCH_UPDATE_SELECTOR))
    {
        ProtocolTransaction::OracleUpdate
    } else {
        ProtocolTransaction::Ordinary
    }
}

/// Classifies a transaction using consensus-fixed sender identities and calldata.
///
/// Uses [`ProtocolRoles::LEGACY`].
pub fn classify_protocol_transaction(sender: Address, input: &[u8]) -> ProtocolTransaction {
    classify_protocol_transaction_with_roles(ProtocolRoles::LEGACY, sender, input)
}

/// A block transaction as the prefix rule reads it.
///
/// `sender` is the recovered signer, or the implicit sender of an unsigned
/// host transaction (EEZ natives recover to their system address).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BlockTransaction<'a> {
    /// EIP-2718 type byte (`0` for legacy).
    pub tx_type: u8,
    /// Recovered or implicit sender.
    pub sender: Address,
    /// Calldata.
    pub input: &'a [u8],
}

/// A protocol transaction found outside its reserved position.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MisplacedProtocolTransaction(pub ProtocolTransaction);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PrefixState {
    /// No transaction yet.
    Start,
    /// Only the host's leading history update so far; both slots are open.
    AfterHostPrefix,
    /// The oracle slot is filled; only the keeper slot is open.
    AfterOracle,
    /// The protocol prefix is over.
    Closed,
}

/// Incremental form of the block rule, for builders and executors that check
/// one transaction at a time.
///
/// It is `Copy`: keep it with any speculative execution state and restore it
/// with that state. [`ProtocolPrefixCursor::after`] proposes the next cursor
/// without mutating this one.
///
/// The roles are bound when the cursor is made and carried through every
/// step, so one block is always classified under one role set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProtocolPrefixCursor {
    roles: ProtocolRoles,
    state: PrefixState,
}

impl Default for ProtocolPrefixCursor {
    /// Same as [`ProtocolPrefixCursor::new`]: [`ProtocolRoles::LEGACY`].
    fn default() -> Self {
        Self::new()
    }
}

impl ProtocolPrefixCursor {
    /// Cursor for an empty block under [`ProtocolRoles::LEGACY`].
    pub const fn new() -> Self {
        Self::with_roles(ProtocolRoles::LEGACY)
    }

    /// Cursor for an empty block under `roles`.
    pub const fn with_roles(roles: ProtocolRoles) -> Self {
        Self {
            roles,
            state: PrefixState::Start,
        }
    }

    /// The roles this cursor classifies with.
    pub const fn roles(&self) -> ProtocolRoles {
        self.roles
    }

    /// The cursor after `transaction`, or why `transaction` is misplaced.
    pub fn after(
        self,
        transaction: BlockTransaction<'_>,
    ) -> Result<Self, MisplacedProtocolTransaction> {
        if self.state == PrefixState::Start && transaction.tx_type == EEZ_HISTORY_TX_TYPE {
            return Ok(Self {
                state: PrefixState::AfterHostPrefix,
                ..self
            });
        }
        self.after_signed(transaction.sender, transaction.input)
    }

    /// The type-free step: every transaction is classified, none is skipped.
    fn after_signed(
        self,
        sender: Address,
        input: &[u8],
    ) -> Result<Self, MisplacedProtocolTransaction> {
        use PrefixState::{AfterHostPrefix, AfterOracle, Closed, Start};
        let role = classify_protocol_transaction_with_roles(self.roles, sender, input);
        let state = match (role, self.state) {
            (ProtocolTransaction::OracleUpdate, Start | AfterHostPrefix) => AfterOracle,
            // An ordinary transaction, or a keeper's in an open slot, ends the prefix.
            (ProtocolTransaction::Ordinary, _)
            | (ProtocolTransaction::Pepl, Start | AfterHostPrefix | AfterOracle) => Closed,
            (role, _) => return Err(MisplacedProtocolTransaction(role)),
        };
        Ok(Self { state, ..self })
    }
}

/// Returns the absolute index of the first transaction outside its reserved
/// position under `roles`, skipping one leading [`EEZ_HISTORY_TX_TYPE`]
/// transaction.
///
/// The valid prefix is `[history?, oracle update?, keeper?]`, followed by
/// ordinary transactions. For a block without a leading `0x46` the verdict
/// equals [`first_protocol_rule_violation_with_roles`] with the same roles.
pub fn first_block_rule_violation_with_roles<'a>(
    roles: ProtocolRoles,
    transactions: impl IntoIterator<Item = BlockTransaction<'a>>,
) -> Option<usize> {
    let mut cursor = ProtocolPrefixCursor::with_roles(roles);
    for (index, transaction) in transactions.into_iter().enumerate() {
        match cursor.after(transaction) {
            Ok(next) => cursor = next,
            Err(_) => return Some(index),
        }
    }
    None
}

/// Returns the absolute index of the first transaction outside its reserved
/// position, skipping one leading [`EEZ_HISTORY_TX_TYPE`] transaction.
///
/// The valid prefix is `[history?, oracle update?, keeper?]`, followed by
/// ordinary transactions. For a block without a leading `0x46` the verdict
/// equals [`first_protocol_rule_violation`].
///
/// Uses [`ProtocolRoles::LEGACY`].
pub fn first_block_rule_violation<'a>(
    transactions: impl IntoIterator<Item = BlockTransaction<'a>>,
) -> Option<usize> {
    first_block_rule_violation_with_roles(ProtocolRoles::LEGACY, transactions)
}

/// Returns the index of the first transaction outside its reserved position
/// under `roles`.
///
/// The valid prefix is `[oracle update?, keeper?]`, as for
/// [`first_protocol_rule_violation`]. Type-free: nothing is skipped.
pub fn first_protocol_rule_violation_with_roles<'a>(
    roles: ProtocolRoles,
    transactions: impl IntoIterator<Item = (Address, &'a [u8])>,
) -> Option<usize> {
    let mut cursor = ProtocolPrefixCursor::with_roles(roles);
    for (index, (sender, input)) in transactions.into_iter().enumerate() {
        match cursor.after_signed(sender, input) {
            Ok(next) => cursor = next,
            Err(_) => return Some(index),
        }
    }
    None
}

/// Returns the index of the first transaction outside its reserved position.
///
/// The current valid prefix is `[oracle update?, keeper?]`: an oracle update
/// may only occur at index zero, and a keeper transaction may occur at index
/// zero when there is no update or at index one immediately after an update.
/// Ordinary transactions follow the optional protocol prefix.
///
/// Type-free: callers on Ethereum-typed chains (Hydreth, eez-rollup0, the
/// current ZisK guest) keep this signature and verdict. Uses
/// [`ProtocolRoles::LEGACY`].
pub fn first_protocol_rule_violation<'a>(
    transactions: impl IntoIterator<Item = (Address, &'a [u8])>,
) -> Option<usize> {
    first_protocol_rule_violation_with_roles(ProtocolRoles::LEGACY, transactions)
}

#[cfg(test)]
mod tests {
    use super::*;

    const USER: Address = address!("0000000000000000000000000000000000000001");
    /// EEZ rollupX SYSTEM_ADDRESS, the implicit sender of 0x45/0x46.
    const EEZ_SYSTEM: Address = address!("fffffffffffffffffffffffffffffffffffffffe");
    const EMPTY: &[u8] = &[];
    const ORACLE_CALL: &[u8] = &[0x51, 0x32, 0x3f, 0x72];
    const BATCH_ORACLE_CALL: &[u8] = &[0xec, 0xb1, 0xc8, 0x5a];
    const LOAD_TABLE_CALL: &[u8] = &[0x01, 0x02, 0x03, 0x04];

    /// The classifier as shipped in hydration-zisk be2aeb5 / eez-rollup0
    /// fbfd742, verbatim, so the references below do not go through the
    /// role-parameterised code under test.
    fn shipped_classify(sender: Address, input: &[u8]) -> ProtocolTransaction {
        if sender == PEPL_KEEPER_ADDRESS {
            ProtocolTransaction::Pepl
        } else if sender == ORACLE_UPDATER_ADDRESS
            && (input.starts_with(&ORACLE_UPDATE_SELECTOR)
                || input.starts_with(&ORACLE_BATCH_UPDATE_SELECTOR))
        {
            ProtocolTransaction::OracleUpdate
        } else {
            ProtocolTransaction::Ordinary
        }
    }

    /// The rule as shipped in hydration-zisk be2aeb5 / eez-rollup0 fbfd742,
    /// verbatim apart from calling [`shipped_classify`].
    #[allow(clippy::match_same_arms)] // kept verbatim; pedantic in rollupX
    fn legacy_first_violation<'a>(
        transactions: impl IntoIterator<Item = (Address, &'a [u8])>,
    ) -> Option<usize> {
        let mut first_is_oracle = false;
        for (index, (sender, input)) in transactions.into_iter().enumerate() {
            match shipped_classify(sender, input) {
                ProtocolTransaction::Ordinary => {}
                ProtocolTransaction::OracleUpdate if index == 0 => first_is_oracle = true,
                ProtocolTransaction::OracleUpdate => return Some(index),
                ProtocolTransaction::Pepl if index == 0 || (index == 1 && first_is_oracle) => {}
                ProtocolTransaction::Pepl => return Some(index),
            }
        }
        None
    }

    fn violation(transactions: &[(Address, &[u8])]) -> Option<usize> {
        first_protocol_rule_violation(transactions.iter().map(|(sender, input)| (*sender, *input)))
    }

    fn typed(transactions: &[(u8, Address, &'static [u8])]) -> Option<usize> {
        first_block_rule_violation(transactions.iter().map(|&(tx_type, sender, input)| {
            BlockTransaction {
                tx_type,
                sender,
                input,
            }
        }))
    }

    /// Distinct classification inputs, including look-alikes.
    const ALPHABET: [(Address, &[u8]); 7] = [
        (USER, EMPTY),
        (USER, ORACLE_CALL),
        (ORACLE_UPDATER_ADDRESS, ORACLE_CALL),
        (ORACLE_UPDATER_ADDRESS, BATCH_ORACLE_CALL),
        (ORACLE_UPDATER_ADDRESS, EMPTY),
        (PEPL_KEEPER_ADDRESS, EMPTY),
        (PEPL_KEEPER_ADDRESS, ORACLE_CALL),
    ];
    /// Non-0x46 type bytes seen on Ethereum-typed and EEZ chains.
    const OTHER_TYPES: [u8; 5] = [0x00, 0x01, 0x02, 0x04, 0x45];

    /// A signed transaction as the type-free rule reads it.
    type Signed = (Address, &'static [u8]);

    fn for_each_sequence(max_len: usize, mut f: impl FnMut(&[Signed])) {
        let mut sequence = Vec::new();
        fn go(sequence: &mut Vec<Signed>, max_len: usize, f: &mut dyn FnMut(&[Signed])) {
            f(sequence);
            if sequence.len() == max_len {
                return;
            }
            for item in ALPHABET {
                sequence.push(item);
                go(sequence, max_len, f);
                sequence.pop();
            }
        }
        go(&mut sequence, max_len, &mut f);
    }

    /// Backward compatibility: without a leading 0x46 the new code returns the
    /// legacy verdict, both through the unchanged signature and through the
    /// typed entry point with any other type byte.
    #[test]
    fn exhaustive_equivalence_with_legacy_rule_without_history() {
        let mut checked = 0usize;
        for_each_sequence(6, |sequence| {
            let legacy = legacy_first_violation(sequence.iter().copied());
            assert_eq!(violation(sequence), legacy, "{sequence:?}");
            for n in 0..OTHER_TYPES.len() {
                let typed_verdict = first_block_rule_violation(sequence.iter().enumerate().map(
                    |(i, &(sender, input))| BlockTransaction {
                        // Vary the type per position so mixed-type blocks are covered.
                        tx_type: OTHER_TYPES[(n + i) % OTHER_TYPES.len()],
                        sender,
                        input,
                    },
                ));
                assert_eq!(typed_verdict, legacy, "{sequence:?} types from {n}");
            }
            checked += 1;
        });
        // 1 + 7 + 7^2 + ... + 7^6
        assert_eq!(checked, 137_257);
    }

    /// One leading 0x46 shifts the legacy prefix by exactly one position.
    #[test]
    fn exhaustive_leading_history_shifts_the_prefix_by_one() {
        for_each_sequence(5, |sequence| {
            let expected = legacy_first_violation(sequence.iter().copied()).map(|i| i + 1);
            let block = core::iter::once(BlockTransaction {
                tx_type: EEZ_HISTORY_TX_TYPE,
                sender: EEZ_SYSTEM,
                input: EMPTY,
            })
            .chain(sequence.iter().map(|&(sender, input)| BlockTransaction {
                tx_type: 0x02,
                sender,
                input,
            }));
            assert_eq!(first_block_rule_violation(block), expected, "{sequence:?}");
        });
    }

    /// A 0x46 anywhere but index zero is not skipped: it is an ordinary
    /// transaction (EEZ's executor rejects it separately).
    #[test]
    fn exhaustive_non_leading_history_is_ordinary() {
        for_each_sequence(4, |sequence| {
            for at in 1..=sequence.len() {
                let mut with_history: Vec<_> = sequence
                    .iter()
                    .map(|&(sender, input)| BlockTransaction {
                        tx_type: 0x02,
                        sender,
                        input,
                    })
                    .collect();
                with_history.insert(
                    at,
                    BlockTransaction {
                        tx_type: EEZ_HISTORY_TX_TYPE,
                        sender: EEZ_SYSTEM,
                        input: EMPTY,
                    },
                );
                let mut as_ordinary: Vec<_> = sequence.to_vec();
                as_ordinary.insert(at, (USER, EMPTY));
                assert_eq!(
                    first_block_rule_violation(with_history.iter().copied()),
                    legacy_first_violation(as_ordinary.iter().copied()),
                    "{sequence:?} history at {at}"
                );
            }
        });
    }

    #[test]
    fn rollupx_history_block_accepts_history_oracle_keeper_then_users() {
        assert_eq!(
            typed(&[
                (0x46, EEZ_SYSTEM, EMPTY),
                (0x02, ORACLE_UPDATER_ADDRESS, ORACLE_CALL),
                (0x02, PEPL_KEEPER_ADDRESS, EMPTY),
                (0x02, USER, EMPTY),
            ]),
            None
        );
        assert_eq!(
            typed(&[
                (0x46, EEZ_SYSTEM, EMPTY),
                (0x02, PEPL_KEEPER_ADDRESS, EMPTY),
                (0x02, USER, EMPTY)
            ]),
            None
        );
        // The legacy, type-free rule rejects the same history block at index 1.
        assert_eq!(
            violation(&[
                (EEZ_SYSTEM, EMPTY),
                (ORACLE_UPDATER_ADDRESS, ORACLE_CALL),
                (PEPL_KEEPER_ADDRESS, EMPTY),
            ]),
            Some(1)
        );
    }

    #[test]
    fn rollupx_history_block_rejects_oracle_after_a_user() {
        assert_eq!(
            typed(&[
                (0x46, EEZ_SYSTEM, EMPTY),
                (0x02, USER, EMPTY),
                (0x02, ORACLE_UPDATER_ADDRESS, ORACLE_CALL),
            ]),
            Some(2)
        );
    }

    /// Sync block: [history?] [0x45 load, signed user]* [0x45 inbound]*.
    /// A protocol transaction as the outbound user is misplaced.
    #[test]
    fn rollupx_sync_block_rejects_protocol_transaction_as_outbound_user() {
        assert_eq!(
            typed(&[
                (0x46, EEZ_SYSTEM, EMPTY),
                (0x45, EEZ_SYSTEM, LOAD_TABLE_CALL),
                (0x02, ORACLE_UPDATER_ADDRESS, ORACLE_CALL),
            ]),
            Some(2)
        );
        assert_eq!(
            typed(&[
                (0x45, EEZ_SYSTEM, LOAD_TABLE_CALL),
                (0x02, PEPL_KEEPER_ADDRESS, EMPTY)
            ]),
            Some(1)
        );
        assert_eq!(
            typed(&[
                (0x46, EEZ_SYSTEM, EMPTY),
                (0x45, EEZ_SYSTEM, LOAD_TABLE_CALL),
                (0x02, USER, EMPTY),
                (0x45, EEZ_SYSTEM, LOAD_TABLE_CALL),
            ]),
            None
        );
    }

    #[test]
    fn cursor_is_side_effect_free_until_committed() {
        let start = ProtocolPrefixCursor::new();
        let oracle = BlockTransaction {
            tx_type: 0x02,
            sender: ORACLE_UPDATER_ADDRESS,
            input: ORACLE_CALL,
        };
        let proposed = start.after(oracle).unwrap();
        // A builder that discards the transaction keeps `start`; the slot is still open.
        assert_eq!(start.after(oracle), Ok(proposed));
        assert_eq!(
            proposed.after(oracle),
            Err(MisplacedProtocolTransaction(
                ProtocolTransaction::OracleUpdate
            ))
        );
    }

    // ---- role-parameterised rule ----

    /// Role holders that are neither dev-mnemonic accounts nor `USER` nor
    /// `EEZ_SYSTEM`, as a rollupX genesis would configure them.
    const CUSTOM: ProtocolRoles = ProtocolRoles::new(
        address!("00000000000000000000000000000000000a0001"),
        address!("00000000000000000000000000000000000b0002"),
    );
    const HISTORY: (u8, Address, &[u8]) = (EEZ_HISTORY_TX_TYPE, EEZ_SYSTEM, EMPTY);

    fn violation_with_roles(
        roles: ProtocolRoles,
        transactions: &[(Address, &[u8])],
    ) -> Option<usize> {
        first_protocol_rule_violation_with_roles(roles, transactions.iter().copied())
    }

    fn typed_with_roles(
        roles: ProtocolRoles,
        transactions: &[(u8, Address, &'static [u8])],
    ) -> Option<usize> {
        first_block_rule_violation_with_roles(
            roles,
            transactions
                .iter()
                .map(|&(tx_type, sender, input)| BlockTransaction {
                    tx_type,
                    sender,
                    input,
                }),
        )
    }

    /// Steps a cursor made with `roles` through the block and returns the
    /// index of the first refused transaction. Every step must keep the roles.
    fn cursor_with_roles(
        roles: ProtocolRoles,
        transactions: &[(u8, Address, &'static [u8])],
    ) -> Option<usize> {
        let mut cursor = ProtocolPrefixCursor::with_roles(roles);
        for (index, &(tx_type, sender, input)) in transactions.iter().enumerate() {
            match cursor.after(BlockTransaction {
                tx_type,
                sender,
                input,
            }) {
                Ok(next) => {
                    assert_eq!(next.roles(), roles);
                    cursor = next;
                }
                Err(_) => return Some(index),
            }
        }
        None
    }

    /// Both typed entry points, with and without a leading history update.
    /// `signed` holds type-0x02 transactions; the verdict is relative to it.
    fn assert_typed_with_roles(
        roles: ProtocolRoles,
        signed: &[(Address, &'static [u8])],
        expected: Option<usize>,
    ) {
        let plain: Vec<_> = signed
            .iter()
            .map(|&(sender, input)| (0x02, sender, input))
            .collect();
        let with_history: Vec<_> = core::iter::once(HISTORY)
            .chain(plain.iter().copied())
            .collect();
        assert_eq!(typed_with_roles(roles, &plain), expected, "{plain:?}");
        assert_eq!(cursor_with_roles(roles, &plain), expected, "{plain:?}");
        let shifted = expected.map(|index| index + 1);
        assert_eq!(
            typed_with_roles(roles, &with_history),
            shifted,
            "{with_history:?}"
        );
        assert_eq!(
            cursor_with_roles(roles, &with_history),
            shifted,
            "{with_history:?}"
        );
    }

    /// Renames the legacy role holders to `CUSTOM`'s; other senders stay.
    fn relabel(sender: Address) -> Address {
        if sender == ORACLE_UPDATER_ADDRESS {
            CUSTOM.oracle_updater
        } else if sender == PEPL_KEEPER_ADDRESS {
            CUSTOM.pepl_keeper
        } else {
            sender
        }
    }

    #[test]
    fn legacy_roles_are_the_shipped_constants() {
        assert_eq!(
            ORACLE_UPDATER_ADDRESS,
            address!("f39fd6e51aad88f6f4ce6ab8827279cfffb92266")
        );
        assert_eq!(
            PEPL_KEEPER_ADDRESS,
            address!("3c44cdddb6a900fa2b585dd299e03d12fa4293bc")
        );
        assert_eq!(
            ProtocolRoles::LEGACY,
            ProtocolRoles {
                oracle_updater: ORACLE_UPDATER_ADDRESS,
                pepl_keeper: PEPL_KEEPER_ADDRESS,
            }
        );
        assert_eq!(ProtocolPrefixCursor::new().roles(), ProtocolRoles::LEGACY);
        assert_eq!(ProtocolPrefixCursor::default(), ProtocolPrefixCursor::new());
        assert_eq!(ProtocolPrefixCursor::with_roles(CUSTOM).roles(), CUSTOM);
    }

    /// The role-free functions are the role-taking ones under `LEGACY`, and
    /// the classifier is the shipped one, including on truncated and extended
    /// calldata.
    #[test]
    fn role_free_functions_delegate_to_legacy_roles() {
        let inputs: [&[u8]; 7] = [
            EMPTY,
            ORACLE_CALL,
            BATCH_ORACLE_CALL,
            LOAD_TABLE_CALL,
            &[0x51, 0x32, 0x3f],
            &[0x51, 0x32, 0x3f, 0x72, 0xff],
            &[0xec, 0xb1, 0xc8, 0x5a, 0x00, 0x00],
        ];
        let senders = [
            USER,
            EEZ_SYSTEM,
            ORACLE_UPDATER_ADDRESS,
            PEPL_KEEPER_ADDRESS,
            CUSTOM.oracle_updater,
            CUSTOM.pepl_keeper,
        ];
        for sender in senders {
            for input in inputs {
                let shipped = shipped_classify(sender, input);
                assert_eq!(classify_protocol_transaction(sender, input), shipped);
                assert_eq!(
                    classify_protocol_transaction_with_roles(ProtocolRoles::LEGACY, sender, input),
                    shipped
                );
            }
        }
        for_each_sequence(4, |sequence| {
            assert_eq!(
                violation_with_roles(ProtocolRoles::LEGACY, sequence),
                violation(sequence),
                "{sequence:?}"
            );
            let block: Vec<_> = core::iter::once(HISTORY)
                .chain(
                    sequence
                        .iter()
                        .map(|&(sender, input)| (0x02, sender, input)),
                )
                .collect();
            assert_eq!(
                typed_with_roles(ProtocolRoles::LEGACY, &block),
                typed(&block),
                "{block:?}"
            );
        });
    }

    #[test]
    fn custom_roles_accept_their_prefix_through_every_entry_point() {
        let oracle = (CUSTOM.oracle_updater, ORACLE_CALL);
        let batch = (CUSTOM.oracle_updater, BATCH_ORACLE_CALL);
        let keeper = (CUSTOM.pepl_keeper, EMPTY);
        let user = (USER, EMPTY);

        let classify = |(sender, input): (Address, &[u8])| {
            classify_protocol_transaction_with_roles(CUSTOM, sender, input)
        };
        assert_eq!(classify(oracle), ProtocolTransaction::OracleUpdate);
        assert_eq!(classify(batch), ProtocolTransaction::OracleUpdate);
        assert_eq!(classify(keeper), ProtocolTransaction::Pepl);
        assert_eq!(
            classify((CUSTOM.pepl_keeper, ORACLE_CALL)),
            ProtocolTransaction::Pepl
        );
        assert_eq!(
            classify((CUSTOM.oracle_updater, EMPTY)),
            ProtocolTransaction::Ordinary
        );

        for block in [
            &[oracle, keeper, user, user][..],
            &[batch, keeper, user],
            &[oracle, user],
            &[keeper, user],
            &[user, user],
            &[],
        ] {
            assert_eq!(violation_with_roles(CUSTOM, block), None, "{block:?}");
            assert_typed_with_roles(CUSTOM, block, None);
        }
    }

    #[test]
    fn custom_roles_reject_misplaced_role_transactions() {
        let oracle = (CUSTOM.oracle_updater, ORACLE_CALL);
        let keeper = (CUSTOM.pepl_keeper, EMPTY);
        let user = (USER, EMPTY);

        for (block, expected) in [
            (&[user, oracle][..], 1),
            (&[oracle, user, keeper], 2),
            (&[keeper, oracle], 1),
            (&[oracle, oracle], 1),
            (&[oracle, keeper, keeper], 2),
            (&[user, keeper], 1),
        ] {
            assert_eq!(
                violation_with_roles(CUSTOM, block),
                Some(expected),
                "{block:?}"
            );
            assert_typed_with_roles(CUSTOM, block, Some(expected));
        }

        let after_oracle = ProtocolPrefixCursor::with_roles(CUSTOM)
            .after(BlockTransaction {
                tx_type: 0x02,
                sender: oracle.0,
                input: oracle.1,
            })
            .unwrap();
        assert_eq!(
            after_oracle.after(BlockTransaction {
                tx_type: 0x02,
                sender: oracle.0,
                input: oracle.1,
            }),
            Err(MisplacedProtocolTransaction(
                ProtocolTransaction::OracleUpdate
            ))
        );
    }

    /// On a chain with its own roles the dev-mnemonic accounts of `LEGACY`
    /// are ordinary senders, wherever they appear and whatever they call.
    #[test]
    fn legacy_dev_keys_are_ordinary_under_custom_roles() {
        for sender in [ORACLE_UPDATER_ADDRESS, PEPL_KEEPER_ADDRESS] {
            for input in [EMPTY, ORACLE_CALL, BATCH_ORACLE_CALL] {
                assert_eq!(
                    classify_protocol_transaction_with_roles(CUSTOM, sender, input),
                    ProtocolTransaction::Ordinary
                );
            }
        }

        // The custom prefix, then legacy role transactions late in the block.
        let block = [
            (CUSTOM.oracle_updater, ORACLE_CALL),
            (CUSTOM.pepl_keeper, EMPTY),
            (USER, EMPTY),
            (ORACLE_UPDATER_ADDRESS, ORACLE_CALL),
            (PEPL_KEEPER_ADDRESS, EMPTY),
            (ORACLE_UPDATER_ADDRESS, BATCH_ORACLE_CALL),
        ];
        assert_eq!(violation_with_roles(CUSTOM, &block), None);
        assert_typed_with_roles(CUSTOM, &block, None);
        // The legacy rule, by contrast, rejects the first dev-key oracle update.
        assert_eq!(violation(&block), Some(3));

        // A dev-key "oracle update" does not fill the oracle slot: it is an
        // ordinary transaction, so the real oracle update after it is misplaced.
        let block = [
            (ORACLE_UPDATER_ADDRESS, ORACLE_CALL),
            (CUSTOM.oracle_updater, ORACLE_CALL),
        ];
        assert_eq!(violation_with_roles(CUSTOM, &block), Some(1));
        assert_typed_with_roles(CUSTOM, &block, Some(1));
    }

    /// Under custom roles the rule is the shipped rule with the role holders
    /// renamed, and a block whose only role-like senders are the legacy dev
    /// keys has no protocol transaction at all.
    #[test]
    fn exhaustive_custom_roles_are_a_relabelling_of_the_shipped_rule() {
        let mut checked = 0usize;
        for_each_sequence(6, |sequence| {
            let legacy = legacy_first_violation(sequence.iter().copied());
            let relabelled: Vec<_> = sequence
                .iter()
                .map(|&(sender, input)| (relabel(sender), input))
                .collect();
            assert_eq!(
                violation_with_roles(CUSTOM, &relabelled),
                legacy,
                "{relabelled:?}"
            );
            assert_eq!(violation_with_roles(CUSTOM, sequence), None, "{sequence:?}");
            checked += 1;
        });
        assert_eq!(checked, 137_257);

        for_each_sequence(5, |sequence| {
            let relabelled: Vec<_> = sequence
                .iter()
                .map(|&(sender, input)| (relabel(sender), input))
                .collect();
            let legacy = legacy_first_violation(sequence.iter().copied());
            assert_typed_with_roles(CUSTOM, &relabelled, legacy);
            assert_typed_with_roles(CUSTOM, sequence, None);
        });
    }

    /// Documents the precedence: the keeper check comes first.
    #[test]
    fn same_address_for_both_roles_is_always_keeper() {
        let account = CUSTOM.oracle_updater;
        let both = ProtocolRoles::new(account, account);
        for input in [EMPTY, ORACLE_CALL, BATCH_ORACLE_CALL] {
            assert_eq!(
                classify_protocol_transaction_with_roles(both, account, input),
                ProtocolTransaction::Pepl
            );
        }
        assert_eq!(
            violation_with_roles(both, &[(account, ORACLE_CALL), (account, ORACLE_CALL)]),
            Some(1)
        );
    }

    // ---- original tests, unchanged ----

    #[test]
    fn accepts_ordinary_transactions() {
        assert_eq!(violation(&[(USER, EMPTY), (USER, EMPTY)]), None);
    }

    #[test]
    fn accepts_oracle_only_prefix() {
        assert_eq!(
            violation(&[(ORACLE_UPDATER_ADDRESS, ORACLE_CALL), (USER, EMPTY)]),
            None
        );
    }

    #[test]
    fn accepts_oracle_then_pepl_then_ordinary_transactions() {
        assert_eq!(
            violation(&[
                (ORACLE_UPDATER_ADDRESS, ORACLE_CALL),
                (PEPL_KEEPER_ADDRESS, EMPTY),
                (USER, EMPTY),
            ]),
            None
        );
    }

    #[test]
    fn classifies_authenticated_batch_update_as_oracle() {
        assert_eq!(
            classify_protocol_transaction(ORACLE_UPDATER_ADDRESS, BATCH_ORACLE_CALL),
            ProtocolTransaction::OracleUpdate
        );
    }

    #[test]
    fn accepts_standalone_pepl_prefix() {
        assert_eq!(
            violation(&[(PEPL_KEEPER_ADDRESS, EMPTY), (USER, EMPTY)]),
            None
        );
    }

    #[test]
    fn rejects_oracle_after_an_ordinary_transaction() {
        assert_eq!(
            violation(&[(USER, EMPTY), (ORACLE_UPDATER_ADDRESS, ORACLE_CALL)]),
            Some(1)
        );
    }

    #[test]
    fn rejects_gap_between_oracle_and_pepl() {
        assert_eq!(
            violation(&[
                (ORACLE_UPDATER_ADDRESS, ORACLE_CALL),
                (USER, EMPTY),
                (PEPL_KEEPER_ADDRESS, EMPTY),
            ]),
            Some(2)
        );
    }

    #[test]
    fn updater_transaction_with_other_calldata_is_ordinary() {
        assert_eq!(
            classify_protocol_transaction(ORACLE_UPDATER_ADDRESS, &[0xde, 0xad, 0xbe, 0xef]),
            ProtocolTransaction::Ordinary
        );
    }

    #[test]
    fn selector_from_untrusted_sender_is_ordinary() {
        assert_eq!(
            classify_protocol_transaction(USER, ORACLE_CALL),
            ProtocolTransaction::Ordinary
        );
    }

    #[test]
    fn batch_selector_from_untrusted_sender_is_ordinary() {
        assert_eq!(
            classify_protocol_transaction(USER, BATCH_ORACLE_CALL),
            ProtocolTransaction::Ordinary
        );
    }

    #[test]
    fn rejects_second_oracle_update() {
        assert_eq!(
            violation(&[
                (ORACLE_UPDATER_ADDRESS, ORACLE_CALL),
                (ORACLE_UPDATER_ADDRESS, ORACLE_CALL),
            ]),
            Some(1)
        );
    }

    #[test]
    fn rejects_second_pepl_transaction() {
        assert_eq!(
            violation(&[
                (ORACLE_UPDATER_ADDRESS, ORACLE_CALL),
                (PEPL_KEEPER_ADDRESS, EMPTY),
                (PEPL_KEEPER_ADDRESS, EMPTY),
            ]),
            Some(2)
        );
    }
}
