const USAGE: &str = "usage: genesis_block_hash <genesis.json> [--network-profile <L1 profile>]\n       \
                     genesis_block_hash --l1-reference <L1 profile>";

fn main() -> eyre::Result<()> {
    let mut args = std::env::args().skip(1);
    let path = args.next().ok_or_else(|| eyre::eyre!(USAGE))?;
    if path == "--l1-reference" {
        let l1_path = args
            .next()
            .ok_or_else(|| eyre::eyre!("missing L1 profile"))?;
        eyre::ensure!(args.next().is_none(), "unexpected genesis tool argument");
        return print_l1_reference(&l1_path);
    }
    let genesis = eez_l1::chain_config::load_l2_genesis(std::path::Path::new(&path))?;
    let chain_spec = eez_evm::profile::chain_spec(genesis.into_genesis())?;
    match args.next().as_deref() {
        None => println!("{}", chain_spec.genesis_header().hash_slow()),
        Some("--network-profile") => {
            let l1_path = args
                .next()
                .ok_or_else(|| eyre::eyre!("missing L1 profile"))?;
            eyre::ensure!(args.next().is_none(), "unexpected genesis tool argument");
            let l1 = eez_l1::chain_config::load_l1_chain_spec(std::path::Path::new(&l1_path))?;
            let rules = eez_l1::chain_config::offline_l1_rules(&l1)?;
            let profile = rules.profile(
                eez_evm::profile::schedule(&chain_spec)?,
                chain_spec.chain().id(),
            )?;
            println!("{}", profile.commitment());
        }
        Some(_) => eyre::bail!("unexpected genesis tool argument"),
    }
    Ok(())
}

/// Print a private L1's block zero in the `cast block --json` fields that an
/// L2 genesis binds as `config.rollupX.l1Reference`. This lets a network whose
/// L1 is embedded in the Composer render its L2 genesis before that L1 runs;
/// the node still authenticates the reference against the live block zero.
fn print_l1_reference(l1_path: &str) -> eyre::Result<()> {
    let l1 = eez_l1::chain_config::load_l1_chain_spec(std::path::Path::new(l1_path))?;
    let header = l1.genesis_header();
    println!(
        r#"{{"number":"{:#x}","hash":"{}","timestamp":"{:#x}","mixHash":"{}"}}"#,
        header.number,
        header.hash_slow(),
        header.timestamp,
        header.mix_hash
    );
    Ok(())
}
