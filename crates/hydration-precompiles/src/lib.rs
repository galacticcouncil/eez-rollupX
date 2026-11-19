//! Hydration's precompiles on evm2, active when the L2 genesis carries
//! `config.hydration` (see the `hydration-config` crate).
//!
//! Rules version 1 defines one: the counter at [`COUNTER_ADDRESS`]. It is the evm2
//! port of hydration-zisk's `hydration-zisk-evm` counter (revm), without its
//! 0x..0801 test control. Selectors, gas schedule, outputs and revert reasons are
//! the same. Gas is charged before any state change: static check, `sload`, charge,
//! nonce bump, `sstore`. An underfunded call therefore halts out of gas without
//! having written anything, rather than relying on the frame rollback.
//!
//! The counter keeps state, so it must never be served from a precompile result
//! cache. Callers that install it must keep caching disabled for this address.

use alloy_primitives::{Bytes, U256};
use evm2::{
    Evm, EvmTypes, Precompiles,
    evm::precompile::PrecompileOutput,
    interpreter::{GasTracker, Host, Message},
    precompiles::{Precompile, PrecompileError, PrecompileId, PrecompileResult},
};

pub use hydration_config::COUNTER_ADDRESS;

/// The single storage slot holding the counter.
pub const COUNTER_SLOT: U256 = U256::ZERO;
/// `increment()`: adds one and returns the new value as one 32-byte word.
pub const SELECTOR_INCREMENT: [u8; 4] = [0xd0, 0x9d, 0xe0, 0x8a];
/// `get()`: returns the current value as one 32-byte word. Legal in STATICCALL.
pub const SELECTOR_GET: [u8; 4] = [0x6d, 0x4c, 0xe6, 0x3c];

const GAS_BASE: u64 = 200;
/// EIP-2929 `COLD_SLOAD_COST`.
const GAS_SLOAD_COLD: u64 = 2100;
/// EIP-2929 `WARM_STORAGE_READ_COST`.
const GAS_SLOAD_WARM: u64 = 100;
/// Flat, not EIP-2200, as in the revm counter.
const GAS_SSTORE: u64 = 5000;

/// Add rules version 1's precompiles to `precompiles`, keeping every existing entry.
pub fn install<T: EvmTypes>(precompiles: &mut Precompiles<T>) {
    precompiles.as_map_mut().insert(Precompile::new(
        COUNTER_ADDRESS,
        PrecompileId::custom("hydration-counter"),
        counter_precompile::<T>,
    ));
}

fn counter_precompile<T: EvmTypes>(
    evm: &mut Evm<'_, T>,
    message: &Message<T>,
    gas: &mut GasTracker,
) -> PrecompileResult {
    // Under DELEGATECALL or CALLCODE the storage would be the caller's, not the counter's.
    if !message.is_direct_call() {
        return revert(gas, "counter: DELEGATECALL/CALLCODE not supported");
    }
    let selector = {
        let input = evm.message_input(message);
        if input.len() < 4 {
            return revert(gas, "counter: missing 4-byte selector");
        }
        [input[0], input[1], input[2], input[3]]
    };
    match selector {
        SELECTOR_GET => get(evm, gas),
        SELECTOR_INCREMENT => increment(evm, message, gas),
        _ => revert(gas, "counter: unknown selector"),
    }
}

fn get<T: EvmTypes>(evm: &mut Evm<'_, T>, gas: &mut GasTracker) -> PrecompileResult {
    let loaded = Host::sload(evm, &COUNTER_ADDRESS, &COUNTER_SLOT, false)?;
    gas.spend(GAS_BASE + sload_gas(loaded.is_cold))?;
    Ok(PrecompileOutput::new(word(loaded.value)))
}

fn increment<T: EvmTypes>(
    evm: &mut Evm<'_, T>,
    message: &Message<T>,
    gas: &mut GasTracker,
) -> PrecompileResult {
    // The precompile table does not enforce STATICCALL; the counter must.
    if message.is_static() {
        return revert(gas, "counter: state modification in a static call");
    }
    let loaded = Host::sload(evm, &COUNTER_ADDRESS, &COUNTER_SLOT, false)?;
    // Charge before any write: an underfunded call changes nothing. The slot warmed
    // by the sload above is un-warmed when the out-of-gas frame reverts.
    gas.spend(GAS_BASE + sload_gas(loaded.is_cold) + GAS_SSTORE)?;
    ensure_account_not_empty(evm)?;
    // Saturating: a counter that would overflow freezes rather than wraps.
    let new_value = loaded.value.saturating_add(U256::from(1u64));
    Host::sstore(evm, &COUNTER_ADDRESS, &COUNTER_SLOT, &new_value, false)?;
    Ok(PrecompileOutput::new(word(new_value)))
}

/// Keep the account non-empty under EIP-161, which ignores storage when deciding
/// emptiness: an account holding only the counter slot would be cleared with it.
/// `config.hydration` requires a genesis seed with nonce 1, which makes this a no-op;
/// it remains so the precompile is also correct on a chain built without the seed.
fn ensure_account_not_empty<T: EvmTypes>(evm: &mut Evm<'_, T>) -> Result<(), PrecompileError> {
    let mut account = evm.state_mut().account(&COUNTER_ADDRESS)?;
    if account.nonce() == 0 {
        account.bump_nonce();
    }
    Ok(())
}

const fn sload_gas(is_cold: bool) -> u64 {
    if is_cold {
        GAS_SLOAD_COLD
    } else {
        GAS_SLOAD_WARM
    }
}

/// ABI-encode a `uint256` as one 32-byte word.
fn word(value: U256) -> Bytes {
    Bytes::from(value.to_be_bytes::<32>().to_vec())
}

/// Revert this call, charging base gas. The reason is raw bytes, not an ABI-encoded
/// `Error(string)`, matching the revm counter.
fn revert(gas: &mut GasTracker, reason: &str) -> PrecompileResult {
    gas.spend(GAS_BASE)?;
    Err(PrecompileError::Revert(Bytes::from(
        reason.as_bytes().to_vec(),
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::keccak256;
    use evm2::{BaseEvmTypes, SpecId, evm::precompile::PrecompileProvider};

    #[test]
    fn selectors_are_the_solidity_signatures() {
        assert_eq!(
            SELECTOR_INCREMENT,
            keccak256("increment()")[..4],
            "increment()"
        );
        assert_eq!(SELECTOR_GET, keccak256("get()")[..4], "get()");
    }

    #[test]
    fn install_adds_the_counter_and_keeps_the_base_table() {
        let base = Precompiles::<BaseEvmTypes>::base(SpecId::OSAKA);
        let mut installed = Precompiles::<BaseEvmTypes>::base(SpecId::OSAKA);
        install(&mut installed);
        assert!(!base.contains(&COUNTER_ADDRESS));
        assert!(installed.contains(&COUNTER_ADDRESS));
        let mut expected = base.addresses();
        expected.push(COUNTER_ADDRESS);
        expected.sort_unstable();
        let mut actual = installed.addresses();
        actual.sort_unstable();
        assert_eq!(actual, expected);
        assert!(
            installed
                .precompile_ids()
                .contains(&(COUNTER_ADDRESS, PrecompileId::custom("hydration-counter")))
        );
    }
}
