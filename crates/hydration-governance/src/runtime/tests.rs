use super::*;
use crate::execution_schedule::{Entry, Release, SchedulePins};
use alloy_primitives::{Address, Bytes, U256, keccak256};
use alloy_provider::ProviderBuilder;
use alloy_sol_types::SolValue;
use alloy_transport::mock::Asserter;

fn identity() -> L2Identity {
    L2Identity {
        chain_id: 31338,
        genesis_hash: keccak256("rehearsal genesis"),
        genesis_timestamp: 1_000,
        block_seconds: 2,
    }
}

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
    let id = identity();
    SchedulePins {
        l1_chain_id: 31337,
        schedule: Address::with_last_byte(1),
        schedule_code_hash: keccak256([1]),
        controller: Address::with_last_byte(2),
        controller_code_hash: keccak256([2]),
        eez_registry: Address::with_last_byte(3),
        rollup_id: 1,
        l2_chain_id: U256::from(id.chain_id),
        l2_genesis_hash: id.genesis_hash,
        l2_genesis_timestamp: id.genesis_timestamp,
        l2_block_seconds: 2,
        max_entries: 100,
        supported_releases: vec![release(0), release(1), release(2)],
    }
}

fn block(number: u64) -> ExecutionBlock {
    ExecutionBlock {
        chain_id: identity().chain_id,
        number,
        timestamp: 1_000 + number * 2,
    }
}

fn reply<T: SolValue>(a: &Asserter, value: T) {
    a.push_success(&Bytes::from(value.abi_encode()));
}

async fn publish(
    context: &RuntimeContext,
    number: u64,
    timestamp: u64,
    version: u32,
) -> Result<(), RuntimeError> {
    let p = pins();
    let a = Asserter::new();
    let mut b: alloy_rpc_types_eth::Block = alloy_rpc_types_eth::Block::default();
    b.header.hash = B256::with_last_byte(number as u8);
    b.header.inner.number = number;
    b.header.inner.timestamp = timestamp;
    a.push_success(&U256::from(p.l1_chain_id));
    a.push_success(&b);
    a.push_success(&Bytes::from(vec![1]));
    a.push_success(&Bytes::from(vec![2]));
    reply(&a, p.controller);
    reply(&a, p.l2_chain_id);
    reply(&a, p.l2_genesis_hash);
    reply(&a, p.l2_genesis_timestamp);
    reply(&a, p.l2_block_seconds);
    reply(&a, p.eez_registry);
    reply(&a, p.rollup_id);
    reply(&a, 1_000u64);
    reply(&a, 200u64);
    reply(&a, U256::from(version + 1));
    for v in 0..=version {
        reply(
            &a,
            Entry {
                activationBlock: match v {
                    0 => 0,
                    1 => 1_000,
                    _ => 3_000,
                },
                upgradeId: if v == 0 {
                    B256::ZERO
                } else {
                    keccak256(format!("upgrade {v}"))
                },
                release: release(v),
            },
        );
    }
    a.push_success(&b);
    a.push_success(&b);
    let provider = ProviderBuilder::new().connect_mocked_client(a);
    context
        .refresh(&mut ExecutionScheduleReader::new(p).unwrap(), &provider)
        .await
}

#[tokio::test]
async fn resolves_boundary_and_historical_replay_without_an_engine() {
    let context = RuntimeContext::new(identity()).unwrap();
    publish(&context, 10, 3_000, 1).await.unwrap();
    for (height, version) in [
        (999, ExecutionVersion::V0),
        (1_000, ExecutionVersion::V1),
        (1_001, ExecutionVersion::V1),
        (999, ExecutionVersion::V0),
    ] {
        assert_eq!(context.resolve(&block(height)).unwrap().1, version);
    }
    assert!(context.resolve(&block(1_101)).is_err());
}

#[tokio::test]
async fn missing_finality_pauses_permits_and_recovery_preserves_history() {
    let context = RuntimeContext::new(identity()).unwrap();
    assert!(context.permit(block(1_000)).is_err());
    publish(&context, 10, 3_000, 1).await.unwrap();
    let permit = context.permit(block(1_000)).unwrap();
    assert!(permit.check().is_ok());
    let a = Asserter::new();
    a.push_success(&U256::from(31337));
    a.push_success(&Option::<alloy_rpc_types_eth::Block>::None);
    let provider = ProviderBuilder::new().connect_mocked_client(a);
    assert!(
        context
            .refresh(
                &mut ExecutionScheduleReader::new(pins()).unwrap(),
                &provider
            )
            .await
            .is_err()
    );
    assert!(permit.check().is_err());
    publish(&context, 11, 3_010, 1).await.unwrap();
    assert!(permit.check().is_ok());
    context.pause("offline");
    assert!(publish(&context, 12, 3_020, 0).await.is_err());
    assert!(permit.check().is_err());
}

#[tokio::test]
async fn rejects_wrong_environment_and_allowlisted_but_unimplemented_version() {
    let context = RuntimeContext::new(identity()).unwrap();
    publish(&context, 10, 3_000, 1).await.unwrap();
    let mut wrong = block(1_000);
    wrong.chain_id += 1;
    assert!(context.resolve(&wrong).is_err());
    wrong = block(1_000);
    wrong.timestamp += 1;
    assert!(context.resolve(&wrong).is_err());
    assert!(matches!(
        publish(&context, 11, 5_000, 2).await,
        Err(RuntimeError::Unsupported(2))
    ));
    assert!(context.resolve(&block(1_000)).is_err());
}

#[tokio::test]
async fn accepts_cancelled_future_tail_but_not_retroactive_activation() {
    let context = RuntimeContext::new(identity()).unwrap();
    publish(&context, 10, 2_000, 1).await.unwrap();
    publish(&context, 11, 2_100, 0).await.unwrap();
    publish(&context, 12, 3_000, 0).await.unwrap();
    assert_eq!(
        context.resolve(&block(1_000)).unwrap().1,
        ExecutionVersion::V0
    );
    assert!(publish(&context, 13, 3_010, 1).await.is_err());
}

#[tokio::test]
async fn rejects_mismatched_consumer_identity_without_mutating_genesis() {
    let mut wrong = identity();
    wrong.block_seconds = 3;
    let context = RuntimeContext::new(wrong).unwrap();
    assert!(publish(&context, 10, 3_000, 1).await.is_err());
    assert!(context.check_identity(identity()).is_err());
    wrong.block_seconds = 0;
    assert!(RuntimeContext::new(wrong).is_err());
}
