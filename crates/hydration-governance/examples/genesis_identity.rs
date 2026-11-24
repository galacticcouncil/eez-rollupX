//! Public deployment identity computed with the same chainspec as the node.
use std::{env, path::PathBuf};

fn main() -> eyre::Result<()> {
    let path = env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .ok_or_else(|| eyre::eyre!("usage: genesis_identity <genesis.json>"))?;
    // Match the shipped genesis_block_hash tool: raw ChainSpec conversion can
    // miss profile validation/normalization and describe a different genesis.
    let genesis = eez_l1::chain_config::load_l2_genesis(&path)?;
    let spec = eez_evm::profile::chain_spec(genesis.into_genesis())?;
    let chain_id = spec.genesis().config.chain_id;
    println!(
        "{}",
        serde_json::json!({"chain_id": chain_id.to_string(), "genesis_hash": spec.genesis_hash(),
        "genesis_timestamp": spec.genesis_header().timestamp, "state_root": spec.genesis_header().state_root})
    );
    Ok(())
}
