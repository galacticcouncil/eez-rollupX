//! Opt-in governance authorization and runtime-schedule rehearsal.
//!
//! This library is not a node or signer dependency. Its schedule is metadata,
//! not authorization to change RollupX's genesis-bound execution profile,
//! validation identity, registered key, or optional Hydration rules.
//! Ordinary production and offline proving never consult its L1 reader.

pub mod execution_schedule;
pub mod execution_version;
pub mod runtime;
