//! Read-only inspection. Does not activate execution or write governance state.
use alloy_provider::ProviderBuilder;
use hydration_governance::execution_schedule::{ExecutionScheduleReader, SchedulePins};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let pins = args
        .next()
        .ok_or("usage: runtime_schedule <pins.json> <L2 block>; set EEZ_L1_RPC_URL")?;
    let block: u64 = args.next().ok_or("missing L2 block")?.parse()?;
    if args.next().is_some() {
        return Err("unexpected argument".into());
    }
    let pins: SchedulePins = serde_json::from_reader(std::fs::File::open(pins)?)?;
    let mut reader = ExecutionScheduleReader::new(pins)?;
    let provider = ProviderBuilder::new()
        .disable_recommended_fillers()
        .connect_http(std::env::var("EEZ_L1_RPC_URL")?.parse()?);
    let snapshot = reader.refresh(&provider).await?;
    let release = snapshot.release_at(block)?;
    println!(
        "finalized_l1_number={} finalized_l1_hash={} safe_through_l2={}",
        snapshot.l1_number,
        snapshot.l1_hash,
        snapshot.safe_through()
    );
    println!("{}", serde_json::to_string_pretty(release)?);
    Ok(())
}
