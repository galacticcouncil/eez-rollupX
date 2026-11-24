//! Height-based runtime selection. A binary supporting a version does not activate it.

/// Runtime identifiers, independent of release tags and governance epochs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum ExecutionVersion {
    /// All pre-launch rules, used at genesis.
    V0 = 0,
    /// First upgrade rehearsal, adding a read-only marker.
    V1 = 1,
}

/// The binary cannot execute this runtime; callers must not fall back to genesis.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UnsupportedExecutionVersion(pub u32);

impl TryFrom<u32> for ExecutionVersion {
    type Error = UnsupportedExecutionVersion;

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::V0),
            1 => Ok(Self::V1),
            other => Err(UnsupportedExecutionVersion(other)),
        }
    }
}

/// Minimal rehearsal schedule. Production callers must obtain its activation
/// from authenticated, finalized governance state, not a prover-supplied hint.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ExecutionSchedule {
    v1_activation: Option<u64>,
}

/// An upgrade cannot replace the genesis runtime.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GenesisMustRemainV0;

impl ExecutionSchedule {
    /// Activate runtime 1 at a non-genesis L2 block.
    pub const fn with_v1_at(activation: u64) -> Result<Self, GenesisMustRemainV0> {
        if activation == 0 {
            return Err(GenesisMustRemainV0);
        }
        Ok(Self {
            v1_activation: Some(activation),
        })
    }

    /// Resolve the rules for a specific height, including historical replay.
    pub const fn version_at(self, block: u64) -> ExecutionVersion {
        match self.v1_activation {
            Some(activation) if block >= activation => ExecutionVersion::V1,
            _ => ExecutionVersion::V0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selection_is_historical_not_the_latest_binary_version() {
        let schedule = ExecutionSchedule::with_v1_at(100).unwrap();
        assert_eq!(schedule.version_at(0), ExecutionVersion::V0);
        assert_eq!(schedule.version_at(99), ExecutionVersion::V0);
        assert_eq!(schedule.version_at(100), ExecutionVersion::V1);
        assert_eq!(schedule.version_at(u64::MAX), ExecutionVersion::V1);
        assert_eq!(schedule.version_at(99), ExecutionVersion::V0);
        assert_eq!(
            ExecutionSchedule::default().version_at(u64::MAX),
            ExecutionVersion::V0
        );
    }

    #[test]
    fn reject_unknown_versions_and_genesis_replacement() {
        assert!(ExecutionSchedule::with_v1_at(0).is_err());
        assert_eq!(ExecutionVersion::try_from(0), Ok(ExecutionVersion::V0));
        assert_eq!(ExecutionVersion::try_from(1), Ok(ExecutionVersion::V1));
        assert_eq!(
            ExecutionVersion::try_from(2),
            Err(UnsupportedExecutionVersion(2))
        );
    }
}
