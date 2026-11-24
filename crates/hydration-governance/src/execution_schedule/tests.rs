use super::*;
use alloy_primitives::Bytes;
use alloy_provider::ProviderBuilder;
use alloy_transport::mock::Asserter;

fn release(version: u32) -> Release {
    Release {
        runtimeVersion: version,
        releaseHash: keccak256(format!("manifest {version}")),
        nodeArtifactHash: keccak256(format!("node {version}")),
        guestArtifactHash: keccak256(format!("guest {version}")),
        programVKey: B256::ZERO,
    }
}

fn pins() -> SchedulePins {
    SchedulePins {
        l1_chain_id: 31337,
        schedule: Address::with_last_byte(1),
        schedule_code_hash: keccak256([1]),
        controller: Address::with_last_byte(2),
        controller_code_hash: keccak256([2]),
        eez_registry: Address::with_last_byte(3),
        rollup_id: 1,
        l2_chain_id: U256::from(31338),
        l2_genesis_hash: keccak256("genesis"),
        l2_genesis_timestamp: 1_000,
        l2_block_seconds: 2,
        max_entries: 100,
        supported_releases: vec![release(0), release(1)],
    }
}

fn entries(upgrade: bool) -> Vec<Entry> {
    let mut result = vec![Entry {
        activationBlock: 0,
        upgradeId: B256::ZERO,
        release: release(0),
    }];
    if upgrade {
        result.push(Entry {
            activationBlock: 1_000,
            upgradeId: keccak256("upgrade"),
            release: release(1),
        });
    }
    result
}

fn snapshot(timestamp: u64, upgrade: bool) -> FinalizedSchedule {
    validate_snapshot(
        &pins(),
        10,
        B256::with_last_byte(10),
        timestamp,
        1_000,
        200,
        entries(upgrade),
    )
    .unwrap()
}

#[test]
fn safe_horizon_blocks_unknown_future_changes() {
    let s = snapshot(2_800, true);
    assert_eq!(s.safe_through(), 1_000);
    assert_eq!(s.release_at(999).unwrap().runtimeVersion, 0);
    assert_eq!(s.release_at(1_000).unwrap().runtimeVersion, 1);
    assert!(matches!(
        s.release_at(1_001),
        Err(ScheduleError::Stale(1_001))
    ));
    // Even a genesis-only snapshot is bounded: an unseen new upgrade could exist.
    let s = snapshot(2_000, false);
    assert_eq!(s.release_at(600).unwrap().runtimeVersion, 0);
    assert!(s.release_at(601).is_err());
}

#[test]
fn finalized_cancellation_is_allowed_only_beyond_previously_safe_horizon() {
    assert!(validate_extension(&snapshot(2_000, true), &snapshot(2_100, false)).is_ok());
    assert!(matches!(
        validate_extension(&snapshot(2_800, true), &snapshot(2_900, false)),
        Err(ScheduleError::FinalityViolation)
    ));
    // A later read cannot insert an upgrade into previously promised old rules.
    assert!(validate_extension(&snapshot(2_800, false), &snapshot(2_900, true)).is_err());
}

#[test]
fn unknown_version_and_same_version_wrong_artifacts_fail_closed() {
    for replacement in [release(2), {
        let mut r = release(1);
        r.nodeArtifactHash = keccak256("wrong");
        r
    }] {
        let mut list = entries(true);
        list[1].release = replacement;
        assert!(matches!(
            validate_snapshot(&pins(), 10, B256::ZERO, 2_000, 1_000, 200, list),
            Err(ScheduleError::Unsupported(_))
        ));
    }
    let mut p = pins();
    p.supported_releases[1].programVKey = keccak256("different key");
    assert!(validate_snapshot(&p, 10, B256::ZERO, 2_000, 1_000, 200, entries(true)).is_err());
}

#[test]
fn malformed_history_and_configuration_are_rejected() {
    let mut p = pins();
    p.l2_block_seconds = 0;
    assert!(ExecutionScheduleReader::new(p).is_err());
    for mutation in 0..5 {
        let mut list = entries(true);
        match mutation {
            0 => list[0].activationBlock = 1,
            1 => list[1].activationBlock = 0,
            2 => list[1].upgradeId = B256::ZERO,
            3 => list[0].release = release(1),
            _ => list[1].release.guestArtifactHash = B256::ZERO,
        }
        assert!(validate_snapshot(&pins(), 10, B256::ZERO, 2_000, 1_000, 200, list).is_err());
    }
    assert!(validate_snapshot(&pins(), 10, B256::ZERO, 999, 1_000, 200, entries(false)).is_err());
    assert!(validate_snapshot(&pins(), 10, B256::ZERO, 2_000, 100, 200, entries(false)).is_err());
}

#[test]
fn horizon_arithmetic_does_not_overflow() {
    let s = validate_snapshot(
        &pins(),
        10,
        B256::ZERO,
        u64::MAX,
        u64::MAX,
        u64::MAX,
        entries(true),
    )
    .unwrap();
    assert!(s.release_at(u64::MAX - 1_000).is_ok());
}

fn block(number: u64, timestamp: u64) -> alloy_rpc_types_eth::Block {
    let mut b: alloy_rpc_types_eth::Block = alloy_rpc_types_eth::Block::default();
    b.header.hash = B256::with_last_byte(number as u8);
    b.header.inner.number = number;
    b.header.inner.timestamp = timestamp;
    b
}

fn reply<T: SolValue>(a: &Asserter, value: T) {
    a.push_success(&Bytes::from(value.abi_encode()));
}

fn responses(a: &Asserter, number: u64, timestamp: u64, upgraded: bool) {
    let p = pins();
    a.push_success(&U256::from(p.l1_chain_id));
    a.push_success(&block(number, timestamp));
    a.push_success(&Bytes::from(vec![1]));
    a.push_success(&Bytes::from(vec![2]));
    reply(a, p.controller);
    reply(a, p.l2_chain_id);
    reply(a, p.l2_genesis_hash);
    reply(a, p.l2_genesis_timestamp);
    reply(a, p.l2_block_seconds);
    reply(a, p.eez_registry);
    reply(a, p.rollup_id);
    reply(a, 1_000u64);
    reply(a, 200u64);
    let entries = entries(upgraded);
    reply(a, U256::from(entries.len()));
    for entry in entries {
        reply(a, entry);
    }
    a.push_success(&block(number, timestamp));
    a.push_success(&block(number, timestamp));
}

#[tokio::test]
async fn reads_finalized_snapshot_and_replaces_cancelled_future_tail() {
    let a = Asserter::new();
    let provider = ProviderBuilder::new().connect_mocked_client(a.clone());
    let mut reader = ExecutionScheduleReader::new(pins()).unwrap();
    responses(&a, 10, 2_000, true);
    let s = reader.refresh(&provider).await.unwrap();
    assert_eq!(s.entries().len(), 2);
    assert_eq!(s.release_at(600).unwrap().runtimeVersion, 0);
    // Prepend prior-finalized canonicality response after the new finalized tag.
    responses(&a, 11, 2_100, false);
    a.write_q().insert(
        2,
        alloy_transport::mock::MockResponse::Success(
            serde_json::value::to_raw_value(&block(10, 2_000)).unwrap(),
        ),
    );
    let s = reader.refresh(&provider).await.unwrap();
    assert_eq!(s.entries().len(), 1);
    assert!(a.read_q().is_empty());
}

#[tokio::test]
async fn missing_finality_never_falls_back_to_latest() {
    let a = Asserter::new();
    let provider = ProviderBuilder::new().connect_mocked_client(a.clone());
    a.push_success(&U256::from(31337));
    a.push_success(&Option::<alloy_rpc_types_eth::Block>::None);
    let mut reader = ExecutionScheduleReader::new(pins()).unwrap();
    assert!(matches!(
        reader.refresh(&provider).await,
        Err(ScheduleError::NoFinality)
    ));
    assert!(reader.previous.is_none());
}

#[tokio::test]
async fn mismatched_chain_code_and_configuration_are_rejected() {
    for field in 0..3 {
        let a = Asserter::new();
        let provider = ProviderBuilder::new().connect_mocked_client(a.clone());
        responses(&a, 10, 2_000, true);
        let mut p = pins();
        match field {
            0 => p.l1_chain_id += 1,
            1 => p.schedule_code_hash = B256::with_last_byte(1),
            _ => p.l2_genesis_hash = keccak256("other chain"),
        }
        let mut reader = ExecutionScheduleReader::new(p).unwrap();
        assert!(matches!(
            reader.refresh(&provider).await,
            Err(ScheduleError::Configuration(_))
        ));
        assert!(reader.previous.is_none());
    }
}

#[tokio::test]
async fn previously_finalized_hash_change_is_fatal() {
    let a = Asserter::new();
    let provider = ProviderBuilder::new().connect_mocked_client(a.clone());
    let mut reader = ExecutionScheduleReader::new(pins()).unwrap();
    responses(&a, 10, 2_000, true);
    reader.refresh(&provider).await.unwrap();
    a.push_success(&U256::from(31337));
    a.push_success(&block(11, 2_010));
    let mut changed = block(10, 2_000);
    changed.header.hash = keccak256("reorg");
    a.push_success(&changed);
    assert!(matches!(
        reader.refresh(&provider).await,
        Err(ScheduleError::FinalityViolation)
    ));
    assert_eq!(reader.previous.as_ref().unwrap().l1_number, 10);
}

#[test]
fn pins_json_roundtrip_retains_full_artifact_identity() {
    let p = pins();
    let json = serde_json::to_string(&p).unwrap();
    let decoded: SchedulePins = serde_json::from_str(&json).unwrap();
    assert_eq!(decoded.supported_releases, p.supported_releases);
}

#[test]
fn snapshot_binds_consumer_identity_and_cannot_switch_reader_deployments() {
    let p = pins();
    let old = snapshot(2_000, false);
    assert!(
        old.check_l2_identity(31338, p.l2_genesis_hash, 1_000, 2)
            .is_ok()
    );
    assert!(
        old.check_l2_identity(31339, p.l2_genesis_hash, 1_000, 2)
            .is_err()
    );
    assert!(
        old.check_l2_identity(31338, keccak256("other genesis"), 1_000, 2)
            .is_err()
    );
    assert!(
        old.check_l2_identity(31338, p.l2_genesis_hash, 1_000, 3)
            .is_err()
    );
    let mut other = pins();
    other.schedule = Address::with_last_byte(99);
    let next = validate_snapshot(
        &other,
        11,
        B256::with_last_byte(11),
        2_010,
        1_000,
        200,
        entries(false),
    )
    .unwrap();
    assert!(old.check_successor(&next).is_err());
    // One finalized block hash cannot have two different storage histories,
    // even when the difference lies beyond the safe execution horizon.
    assert!(old.check_successor(&snapshot(2_000, true)).is_err());
}

fn replace_response<T: serde::Serialize>(a: &Asserter, index: usize, value: T) {
    a.write_q()[index] = alloy_transport::mock::MockResponse::Success(
        serde_json::value::to_raw_value(&value).unwrap(),
    );
}

#[tokio::test]
async fn regression_during_read_and_noncanonical_snapshot_are_rejected() {
    for change in 0..2 {
        let a = Asserter::new();
        let provider = ProviderBuilder::new().connect_mocked_client(a.clone());
        responses(&a, 10, 2_000, true);
        if change == 0 {
            replace_response(&a, 17, block(9, 1_990));
        } else {
            let mut changed = block(10, 2_000);
            changed.header.hash = keccak256("noncanonical");
            replace_response(&a, 16, changed);
        }
        let mut reader = ExecutionScheduleReader::new(pins()).unwrap();
        assert!(matches!(
            reader.refresh(&provider).await,
            Err(ScheduleError::FinalityViolation)
        ));
        assert!(reader.previous.is_none());
    }
}

#[tokio::test]
async fn malformed_abi_count_bounds_and_unsupported_snapshot_never_enter_cache() {
    for change in 0..4 {
        let a = Asserter::new();
        let provider = ProviderBuilder::new().connect_mocked_client(a.clone());
        responses(&a, 10, 2_000, true);
        let mut p = pins();
        match change {
            0 => replace_response(&a, 13, Bytes::from(U256::MAX.abi_encode())),
            1 => replace_response(&a, 14, Bytes::from(vec![0])),
            2 => p.max_entries = 1,
            _ => {
                p.supported_releases.pop();
            }
        }
        let mut reader = ExecutionScheduleReader::new(p).unwrap();
        assert!(reader.refresh(&provider).await.is_err());
        assert!(reader.previous.is_none());
    }
}

#[test]
fn rejects_multiple_pending_entries_even_if_every_version_is_supported() {
    let mut p = pins();
    p.supported_releases.push(release(2));
    let mut list = entries(true);
    list.push(Entry {
        activationBlock: 2_000,
        upgradeId: keccak256("second upgrade"),
        release: release(2),
    });
    assert!(matches!(
        validate_snapshot(&p, 10, B256::ZERO, 2_000, 1_000, 200, list),
        Err(ScheduleError::Invalid("multiple pending upgrades"))
    ));
}
