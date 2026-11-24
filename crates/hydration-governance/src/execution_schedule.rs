//! Fail-closed runtime schedule reads from a trusted L1 RPC's finalized state.
//!
//! Every eth_call/code read is pinned to one canonical block hash (EIP-1898).
//! No latest/head/confirmation-count fallback. This is RPC authentication, not
//! a cryptographic state proof. Execution consumers are not wired here yet.

use alloy_eips::{BlockId, BlockNumberOrTag, RpcBlockHash};
use alloy_primitives::{Address, B256, U256, keccak256};
use alloy_provider::Provider;
use alloy_rpc_types_eth::TransactionRequest;
use alloy_sol_types::{SolCall, SolValue, sol};
use serde::{Deserialize, Serialize};
use thiserror::Error;

sol! {
    /// ABI of the controller-owned activation registry.
    interface ScheduleAbi {
        #[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
        struct Release {
            uint32 runtimeVersion;
            bytes32 releaseHash;
            bytes32 nodeArtifactHash;
            bytes32 guestArtifactHash;
            bytes32 programVKey;
        }
        #[derive(Debug, PartialEq, Eq)]
        struct Entry { uint64 activationBlock; bytes32 upgradeId; Release release; }
        function CONTROLLER() external view returns (address);
        function L2_CHAIN_ID() external view returns (uint256);
        function L2_GENESIS_HASH() external view returns (bytes32);
        function L2_GENESIS_TIMESTAMP() external view returns (uint64);
        function L2_BLOCK_SECONDS() external view returns (uint64);
        function MIN_NOTICE() external view returns (uint64);
        function CANCEL_NOTICE() external view returns (uint64);
        function entryCount() external view returns (uint256);
        function entryAt(uint256 index) external view returns (Entry);
    }
    interface ControllerAbi {
        function EEZ_REGISTRY() external view returns (address);
        function ROLLUP_ID() external view returns (uint64);
    }
}

pub use ScheduleAbi::{Entry, Release};

/// Operator-pinned deployment and binary compatibility configuration.
/// `supported_releases` must come from the locally verified release/build, NOT
/// from the governance contract being read. Every artifact/key field must match.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SchedulePins {
    pub l1_chain_id: u64,
    pub schedule: Address,
    pub schedule_code_hash: B256,
    pub controller: Address,
    pub controller_code_hash: B256,
    pub eez_registry: Address,
    pub rollup_id: u64,
    pub l2_chain_id: U256,
    pub l2_genesis_hash: B256,
    pub l2_genesis_timestamp: u64,
    pub l2_block_seconds: u64,
    /// Resource bound, not a consensus parameter. Raise explicitly as history grows.
    pub max_entries: usize,
    pub supported_releases: Vec<Release>,
}

#[derive(Debug, Error)]
pub enum ScheduleError {
    #[error("schedule RPC: {0}")]
    Rpc(String),
    #[error("L1 source has no finalized block; no latest-state fallback")]
    NoFinality,
    #[error("schedule deployment/configuration mismatch: {0}")]
    Configuration(&'static str),
    #[error("invalid schedule state: {0}")]
    Invalid(&'static str),
    #[error("unsupported release at runtime {0}; install and verify matching artifacts")]
    Unsupported(u32),
    #[error("finalized chain regressed or previously finalized history changed")]
    FinalityViolation,
    #[error("schedule snapshot is too stale for L2 block {0}; refresh finalized state")]
    Stale(u64),
}

type Result<T> = std::result::Result<T, ScheduleError>;

/// An immutable validated snapshot, including its finality/freshness boundary.
#[derive(Debug, Clone)]
pub struct FinalizedSchedule {
    pub l1_number: u64,
    pub l1_hash: B256,
    pub l1_timestamp: u64,
    l2_chain_id: U256,
    l2_genesis_hash: B256,
    source_id: B256,
    genesis_timestamp: u64,
    block_seconds: u64,
    horizon_timestamp: u128,
    entries: Vec<Entry>,
}

impl FinalizedSchedule {
    /// Prevent mixing reader sources or rewriting an already-safe prefix when
    /// an execution context receives snapshots across a pause/recovery cycle.
    /// Canonicality of intermediate L1 ancestry still belongs to the reader/RPC.
    pub fn check_successor(&self, next: &Self) -> Result<()> {
        if self.source_id != next.source_id
            || self.l2_chain_id != next.l2_chain_id
            || self.l2_genesis_hash != next.l2_genesis_hash
            || self.genesis_timestamp != next.genesis_timestamp
            || self.block_seconds != next.block_seconds
            || next.l1_number < self.l1_number
            || next.l1_timestamp < self.l1_timestamp
            || (self.l1_number == next.l1_number
                && (self.l1_hash != next.l1_hash
                    || self.l1_timestamp != next.l1_timestamp
                    || self.entries != next.entries))
        {
            return Err(ScheduleError::FinalityViolation);
        }
        validate_extension(self, next)
    }
    /// Bind a consumer's actual chainspec and slot cadence to this snapshot.
    pub fn check_l2_identity(
        &self,
        chain_id: u64,
        genesis_hash: B256,
        genesis_timestamp: u64,
        block_seconds: u64,
    ) -> Result<()> {
        if self.l2_chain_id != U256::from(chain_id)
            || self.l2_genesis_hash != genesis_hash
            || self.genesis_timestamp != genesis_timestamp
            || self.block_seconds != block_seconds
        {
            return Err(ScheduleError::Configuration(
                "execution consumer L2 identity",
            ));
        }
        Ok(())
    }
    /// Last L2 height for which unseen changes cannot affect runtime selection.
    pub fn safe_through(&self) -> u64 {
        ((self.horizon_timestamp - u128::from(self.genesis_timestamp))
            / u128::from(self.block_seconds))
        .min(u128::from(u64::MAX)) as u64
    }

    /// Resolve only within the snapshot's safe horizon. Never assumes that a
    /// stale view of the future remains approved after a possible cancellation.
    pub fn release_at(&self, block: u64) -> Result<&Release> {
        if block > self.safe_through() {
            return Err(ScheduleError::Stale(block));
        }
        Ok(&self.entries[self.entries.partition_point(|e| e.activationBlock <= block) - 1].release)
    }

    /// Includes a possible pending tail, which is not executable beyond the horizon.
    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }
}

/// Read/validate primitive. Callers own polling and must honor refresh errors.
/// Retains the last successful snapshot only to detect finalized-history rewrites.
#[derive(Debug)]
pub struct ExecutionScheduleReader {
    pins: SchedulePins,
    previous: Option<FinalizedSchedule>,
}

impl ExecutionScheduleReader {
    pub fn new(pins: SchedulePins) -> Result<Self> {
        if pins.l1_chain_id == 0
            || pins.schedule.is_zero()
            || pins.controller.is_zero()
            || pins.eez_registry.is_zero()
            || pins.rollup_id == 0
            || pins.l2_chain_id.is_zero()
            || pins.l2_genesis_hash.is_zero()
            || pins.schedule_code_hash.is_zero()
            || pins.controller_code_hash.is_zero()
            || pins.l2_block_seconds == 0
            || pins.max_entries == 0
            || pins.max_entries > 100_000
            || !pins
                .supported_releases
                .iter()
                .any(|r| r.runtimeVersion == 0)
        {
            return Err(ScheduleError::Configuration(
                "missing pins, genesis release, or invalid entry bound",
            ));
        }
        for release in &pins.supported_releases {
            validate_release(release)?;
        }
        Ok(Self {
            pins,
            previous: None,
        })
    }

    /// Reads one consistent finalized snapshot. A cancellation is naturally
    /// reflected by rereading the full retained entry list; unfinalized reorgs
    /// never enter the cache. Violations of prior finality are fatal errors.
    pub async fn refresh<P: Provider>(&mut self, provider: &P) -> Result<FinalizedSchedule> {
        let chain = provider.get_chain_id().await.map_err(rpc)?;
        if chain != self.pins.l1_chain_id {
            return Err(ScheduleError::Configuration("L1 chain id"));
        }
        let header = provider
            .get_block_by_number(BlockNumberOrTag::Finalized)
            .await
            .map_err(rpc)?
            .ok_or(ScheduleError::NoFinality)?
            .header;
        if let Some(old) = &self.previous {
            if header.number < old.l1_number || header.timestamp < old.l1_timestamp {
                return Err(ScheduleError::FinalityViolation);
            }
            check_canonical(provider, old.l1_number, old.l1_hash).await?;
        }
        let at = BlockId::Hash(RpcBlockHash::from_hash(header.hash, Some(true)));
        let p = &self.pins;
        for (address, expected) in [
            (p.schedule, p.schedule_code_hash),
            (p.controller, p.controller_code_hash),
        ] {
            let code = provider
                .get_code_at(address)
                .block_id(at)
                .await
                .map_err(rpc)?;
            if code.is_empty() || keccak256(code) != expected {
                return Err(ScheduleError::Configuration("contract runtime code hash"));
            }
        }
        macro_rules! read {
            ($call:expr) => {
                call(provider, p.schedule, at, $call).await?
            };
        }
        if read!(ScheduleAbi::CONTROLLERCall {}) != p.controller
            || read!(ScheduleAbi::L2_CHAIN_IDCall {}) != p.l2_chain_id
            || read!(ScheduleAbi::L2_GENESIS_HASHCall {}) != p.l2_genesis_hash
            || read!(ScheduleAbi::L2_GENESIS_TIMESTAMPCall {}) != p.l2_genesis_timestamp
            || read!(ScheduleAbi::L2_BLOCK_SECONDSCall {}) != p.l2_block_seconds
            || call(
                provider,
                p.controller,
                at,
                ControllerAbi::EEZ_REGISTRYCall {},
            )
            .await?
                != p.eez_registry
            || call(provider, p.controller, at, ControllerAbi::ROLLUP_IDCall {}).await?
                != p.rollup_id
        {
            return Err(ScheduleError::Configuration(
                "controller, rollup, or L2 genesis/grid",
            ));
        }
        let notice = read!(ScheduleAbi::MIN_NOTICECall {});
        let cancel_notice = read!(ScheduleAbi::CANCEL_NOTICECall {});
        let count = usize::try_from(read!(ScheduleAbi::entryCountCall {}))
            .map_err(|_| ScheduleError::Invalid("entry count overflow"))?;
        if count == 0 || count > p.max_entries {
            return Err(ScheduleError::Invalid("entry count bound"));
        }
        let mut entries = Vec::with_capacity(count);
        for index in 0..count {
            entries.push(read!(ScheduleAbi::entryAtCall {
                index: U256::from(index)
            }));
        }
        let snapshot = validate_snapshot(
            p,
            header.number,
            header.hash,
            header.timestamp,
            notice,
            cancel_notice,
            entries,
        )?;
        if let Some(old) = &self.previous {
            old.check_successor(&snapshot)?;
        }
        // EIP-1898 checks every read; also detect an endpoint whose finalized tag
        // regresses while this snapshot is being assembled.
        check_canonical(provider, header.number, header.hash).await?;
        let final_now = provider
            .get_block_by_number(BlockNumberOrTag::Finalized)
            .await
            .map_err(rpc)?
            .ok_or(ScheduleError::NoFinality)?
            .header;
        if final_now.number < header.number
            || final_now.timestamp < header.timestamp
            || (final_now.number == header.number && final_now.hash != header.hash)
        {
            return Err(ScheduleError::FinalityViolation);
        }
        self.previous = Some(snapshot.clone());
        Ok(snapshot)
    }
}

fn rpc(error: impl std::fmt::Display) -> ScheduleError {
    ScheduleError::Rpc(error.to_string())
}

async fn call<P: Provider, C: SolCall>(
    provider: &P,
    address: Address,
    at: BlockId,
    args: C,
) -> Result<C::Return> {
    let data = provider
        .call(
            TransactionRequest::default()
                .to(address)
                .input(args.abi_encode().into()),
        )
        .block(at)
        .await
        .map_err(rpc)?;
    C::abi_decode_returns_validate(&data).map_err(|_| ScheduleError::Invalid("ABI response"))
}

async fn check_canonical<P: Provider>(provider: &P, number: u64, hash: B256) -> Result<()> {
    let canonical = provider
        .get_block_by_number(BlockNumberOrTag::Number(number))
        .await
        .map_err(rpc)?;
    if canonical.is_none_or(|b| b.header.hash != hash) {
        return Err(ScheduleError::FinalityViolation);
    }
    Ok(())
}

fn validate_release(release: &Release) -> Result<()> {
    if release.releaseHash.is_zero()
        || release.nodeArtifactHash.is_zero()
        || release.guestArtifactHash.is_zero()
    {
        return Err(ScheduleError::Invalid("empty manifest or artifact hash"));
    }
    Ok(())
}

fn validate_snapshot(
    p: &SchedulePins,
    number: u64,
    hash: B256,
    timestamp: u64,
    notice: u64,
    cancel_notice: u64,
    entries: Vec<Entry>,
) -> Result<FinalizedSchedule> {
    if timestamp < p.l2_genesis_timestamp
        || notice == 0
        || cancel_notice == 0
        || cancel_notice > notice
        || entries.is_empty()
        || entries.len() > p.max_entries
    {
        return Err(ScheduleError::Invalid("timestamp, notice, or entry count"));
    }
    for (index, entry) in entries.iter().enumerate() {
        validate_release(&entry.release)?;
        if !p.supported_releases.contains(&entry.release) {
            return Err(ScheduleError::Unsupported(entry.release.runtimeVersion));
        }
        if index == 0 {
            if entry.activationBlock != 0
                || entry.release.runtimeVersion != 0
                || !entry.upgradeId.is_zero()
            {
                return Err(ScheduleError::Invalid("genesis entry"));
            }
        } else {
            let previous = &entries[index - 1];
            if entry.activationBlock <= previous.activationBlock
                || entry.upgradeId.is_zero()
                || u64::from(entry.release.runtimeVersion)
                    != u64::from(previous.release.runtimeVersion) + 1
                || entry.release.releaseHash == previous.release.releaseHash
            {
                return Err(ScheduleError::Invalid("unordered or discontinuous history"));
            }
            let previous_time = u128::from(p.l2_genesis_timestamp)
                + u128::from(previous.activationBlock) * u128::from(p.l2_block_seconds);
            if previous_time > u128::from(timestamp) {
                return Err(ScheduleError::Invalid("multiple pending upgrades"));
            }
        }
    }
    // After finalized timestamp T, unseen enactments cannot affect a block
    // before T+MIN_NOTICE, nor cancellations before T+CANCEL_NOTICE. Use the
    // conservative minimum. No execution past this horizon without a refresh.
    Ok(FinalizedSchedule {
        l1_number: number,
        l1_hash: hash,
        l1_timestamp: timestamp,
        l2_chain_id: p.l2_chain_id,
        l2_genesis_hash: p.l2_genesis_hash,
        source_id: keccak256(
            (
                p.l1_chain_id,
                p.schedule,
                p.schedule_code_hash,
                p.controller,
                p.controller_code_hash,
                p.eez_registry,
                p.rollup_id,
            )
                .abi_encode(),
        ),
        genesis_timestamp: p.l2_genesis_timestamp,
        block_seconds: p.l2_block_seconds,
        horizon_timestamp: u128::from(timestamp) + u128::from(notice.min(cancel_notice)),
        entries,
    })
}

fn validate_extension(old: &FinalizedSchedule, new: &FinalizedSchedule) -> Result<()> {
    let cutoff = old.safe_through();
    let old_prefix: Vec<_> = old
        .entries
        .iter()
        .filter(|e| e.activationBlock <= cutoff)
        .collect();
    let new_prefix: Vec<_> = new
        .entries
        .iter()
        .filter(|e| e.activationBlock <= cutoff)
        .collect();
    if old_prefix != new_prefix {
        return Err(ScheduleError::FinalityViolation);
    }
    Ok(())
}

#[cfg(test)]
mod tests;
