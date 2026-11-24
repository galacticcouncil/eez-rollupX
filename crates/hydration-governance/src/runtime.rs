//! Explicit governance rehearsal context, independent of any execution engine.
//! This is not attached to RollupX production or the offline signer. Enabling a
//! dynamic rules schedule requires a separately agreed execution/proof contract.

use crate::execution_schedule::{ExecutionScheduleReader, FinalizedSchedule, ScheduleError};
use crate::execution_version::{ExecutionSchedule, ExecutionVersion};
use alloy_primitives::B256;
use alloy_provider::Provider;
use std::sync::{Arc, RwLock};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum RuntimeError {
    #[error("runtime schedule is not ready: {0}")]
    NotReady(String),
    #[error(transparent)]
    Schedule(#[from] ScheduleError),
    #[error("binary does not support runtime {0}")]
    Unsupported(u32),
    #[error("runtime execution environment disagrees with pinned chain/slot grid")]
    Environment,
    #[error("runtime changed during an execution session; discard and retry the block")]
    Changed,
}

/// Clones share one snapshot/error state. A failed refresh must call `pause`,
/// not silently leave an apparently healthy factory serving its prior state.
#[derive(Debug, Clone)]
pub struct RuntimeContext(Arc<Inner>);

/// Public chain identity supplied by an administrative/rehearsal caller.
/// A genesis header alone does not bind RollupX/Hydration extra configuration;
/// the approved release manifest must also bind the complete chain document.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct L2Identity {
    pub chain_id: u64,
    pub genesis_hash: B256,
    pub genesis_timestamp: u64,
    pub block_seconds: u64,
}

/// Engine-neutral block coordinates, not an authorization supplied by a prover.
#[derive(Debug, Clone, Copy)]
pub struct ExecutionBlock {
    pub chain_id: u64,
    pub number: u64,
    pub timestamp: u64,
}

/// Recheck a previously selected rehearsal decision before using it. This does
/// not wrap evm2 or enforce production block admission by itself.
#[derive(Debug, Clone)]
pub struct ExecutionPermit {
    context: RuntimeContext,
    block: ExecutionBlock,
    pub version: ExecutionVersion,
}

impl ExecutionPermit {
    pub fn check(&self) -> Result<(), RuntimeError> {
        if self.context.resolve(&self.block)?.1 != self.version {
            return Err(RuntimeError::Changed);
        }
        Ok(())
    }
}

#[derive(Debug)]
struct Inner {
    chain_id: u64,
    genesis_hash: B256,
    genesis_timestamp: u64,
    block_seconds: u64,
    state: RwLock<State>,
}

#[derive(Debug)]
struct State {
    snapshot: Option<FinalizedSchedule>,
    issue: Option<String>,
}

impl RuntimeContext {
    pub fn new(identity: L2Identity) -> Result<Self, RuntimeError> {
        if identity.block_seconds == 0 || identity.chain_id == 0 || identity.genesis_hash.is_zero()
        {
            return Err(RuntimeError::Environment);
        }
        Ok(Self(Arc::new(Inner {
            chain_id: identity.chain_id,
            genesis_hash: identity.genesis_hash,
            genesis_timestamp: identity.genesis_timestamp,
            block_seconds: identity.block_seconds,
            state: RwLock::new(State {
                snapshot: None,
                issue: Some("waiting for finalized L1 schedule".into()),
            }),
        })))
    }

    /// Install only a reader-validated snapshot. Validate all versions, even a
    /// pending one beyond the current safe horizon, before declaring readiness.
    pub fn publish(&self, snapshot: FinalizedSchedule) -> Result<(), RuntimeError> {
        let checked = (|| {
            snapshot.check_l2_identity(
                self.0.chain_id,
                self.0.genesis_hash,
                self.0.genesis_timestamp,
                self.0.block_seconds,
            )?;
            for entry in snapshot.entries() {
                ExecutionVersion::try_from(entry.release.runtimeVersion)
                    .map_err(|_| RuntimeError::Unsupported(entry.release.runtimeVersion))?;
            }
            Ok::<_, RuntimeError>(())
        })();
        if let Err(error) = checked {
            self.pause(error.to_string());
            return Err(error);
        }
        let mut state = self
            .0
            .state
            .write()
            .map_err(|_| RuntimeError::NotReady("poisoned schedule state".into()))?;
        if let Some(old) = &state.snapshot
            && let Err(error) = old.check_successor(&snapshot)
        {
            state.issue = Some(error.to_string());
            return Err(error.into());
        }
        state.snapshot = Some(snapshot);
        state.issue = None;
        Ok(())
    }

    /// Read and publish as one fail-closed operation. Polling owners should use
    /// this rather than forgetting to pause execution on an unsuccessful read.
    pub async fn refresh<P: Provider>(
        &self,
        reader: &mut ExecutionScheduleReader,
        provider: &P,
    ) -> Result<(), RuntimeError> {
        match reader.refresh(provider).await {
            Ok(snapshot) => self.publish(snapshot),
            Err(error) => {
                self.pause(error.to_string());
                Err(error.into())
            }
        }
    }

    /// Invalidate rehearsal selections/permits after a refresh failure. Recovery
    /// requires a successful publication; no production engine is paused here.
    pub fn pause(&self, reason: impl Into<String>) {
        if let Ok(mut state) = self.0.state.write() {
            state.issue = Some(reason.into());
        }
    }

    pub fn check_identity(&self, identity: L2Identity) -> Result<(), RuntimeError> {
        if self.0.chain_id != identity.chain_id
            || self.0.genesis_hash != identity.genesis_hash
            || self.0.genesis_timestamp != identity.genesis_timestamp
            || self.0.block_seconds != identity.block_seconds
        {
            return Err(RuntimeError::Environment);
        }
        Ok(())
    }

    /// Resolve a rehearsal decision only inside the snapshot's safe horizon.
    pub fn resolve(
        &self,
        block: &ExecutionBlock,
    ) -> Result<(ExecutionSchedule, ExecutionVersion), RuntimeError> {
        let number = block.number;
        let timestamp = block.timestamp;
        let expected_time = u128::from(self.0.genesis_timestamp)
            + u128::from(number) * u128::from(self.0.block_seconds);
        if block.chain_id != self.0.chain_id || u128::from(timestamp) != expected_time {
            return Err(RuntimeError::Environment);
        }
        let state = self
            .0
            .state
            .read()
            .map_err(|_| RuntimeError::NotReady("poisoned schedule state".into()))?;
        if let Some(reason) = &state.issue {
            return Err(RuntimeError::NotReady(reason.clone()));
        }
        let snapshot = state
            .snapshot
            .as_ref()
            .ok_or_else(|| RuntimeError::NotReady("no snapshot".into()))?;
        let version = ExecutionVersion::try_from(snapshot.release_at(number)?.runtimeVersion)
            .map_err(|error| RuntimeError::Unsupported(error.0))?;
        let schedule = match snapshot.entries().get(1) {
            Some(entry) => ExecutionSchedule::with_v1_at(entry.activationBlock)
                .map_err(|_| RuntimeError::Environment)?,
            None => ExecutionSchedule::default(),
        };
        if schedule.version_at(number) != version {
            return Err(RuntimeError::Changed);
        }
        Ok((schedule, version))
    }

    pub fn permit(&self, block: ExecutionBlock) -> Result<ExecutionPermit, RuntimeError> {
        let version = self.resolve(&block)?.1;
        Ok(ExecutionPermit {
            context: self.clone(),
            block,
            version,
        })
    }
}

#[cfg(test)]
mod tests;
