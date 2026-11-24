//! The L2 genesis extensions: RollupX's required `config.rollupX` and Hydration's
//! optional `config.hydration`. L1 documents retain their own strict schema.

use alloy_genesis::Genesis;
use alloy_primitives::{B256, keccak256};
use eez_protocol::l2::DerivationConfig;
use eyre::WrapErr as _;

use super::{canonicalize_chain_json, parse_document_value};

/// A complete, strictly decoded L2 genesis and the identity of its original
/// document. Structural decoding does not authenticate its L1 reference.
#[derive(Debug)]
pub struct LoadedL2Genesis {
    genesis: Genesis,
    derivation: DerivationConfig,
    digest: B256,
}

impl LoadedL2Genesis {
    /// Includes the `config.rollupX` and any `config.hydration` extension, before any
    /// spelling normalization.
    pub const fn digest(&self) -> B256 {
        self.digest
    }

    /// Immutable timing/reference configuration. Producers and followers
    /// authenticate it against canonical L1; the offline signer instead checks
    /// the complete request ancestry bound to the on-chain settlement anchor.
    pub const fn derivation(&self) -> DerivationConfig {
        self.derivation
    }

    /// Keep the validated extensions in the chain specification so all execution
    /// and reconstruction consumers observe the same genesis parameters.
    pub fn into_genesis(self) -> Genesis {
        self.genesis
    }
}

/// Read one version of the full document, including its derivation parameters.
pub fn load_l2_genesis(path: &std::path::Path) -> eyre::Result<LoadedL2Genesis> {
    let encoded = std::fs::read(path).wrap_err("read L2 genesis document")?;
    parse_l2_genesis(&encoded).wrap_err("parse L2 genesis document")
}

/// Reject duplicate/unknown keys, absent or malformed derivation parameters,
/// a malformed or invalid `config.hydration` and bare chain configurations. Nothing
/// is defaulted from local timing settings. The digest commits to the complete
/// original canonical document, not the temporary Ethereum-only view used to check
/// the common fields. The `config.hydration` alloc seed is checked when the
/// genesis becomes a chain specification (`eez_evm::profile::chain_spec`).
pub fn parse_l2_genesis(encoded: &[u8]) -> eyre::Result<LoadedL2Genesis> {
    let canonical = canonicalize_chain_json(encoded)?;
    let mut document: serde_json::Value = serde_json::from_slice(&canonical)?;
    let config = document
        .get_mut("config")
        .and_then(serde_json::Value::as_object_mut)
        .ok_or_else(|| eyre::eyre!("L2 requires a full Genesis document"))?;
    let extension = config
        .remove("rollupX")
        .ok_or_else(|| eyre::eyre!("L2 genesis requires config.rollupX derivation parameters"))?;
    let derivation: DerivationConfig = serde_json::from_value(extension.clone())
        .wrap_err("invalid config.rollupX derivation parameters")?;
    let hydration = config.remove(hydration_config::GENESIS_FIELD);
    if let Some(section) = &hydration {
        hydration_config::HydrationConfig::decode(section).map_err(eyre::Report::new)?;
    }
    let (mut genesis, _) = parse_document_value(document)?;
    genesis
        .config
        .extra_fields
        .insert("rollupX".into(), extension);
    // Reinsert the original value, not a re-encoding, so consumers decode exactly
    // what the digest covers.
    if let Some(section) = hydration {
        genesis
            .config
            .extra_fields
            .insert(hydration_config::GENESIS_FIELD.into(), section);
    }
    Ok(LoadedL2Genesis {
        genesis,
        derivation,
        digest: keccak256(canonical),
    })
}

#[cfg(test)]
mod tests {
    use super::super::parse_chain_document_with_digest;
    use super::*;
    use eez_protocol::l2::GenesisL1Reference;

    fn document() -> serde_json::Value {
        let mut doc: serde_json::Value =
            serde_json::from_slice(include_bytes!("../../../../genesis.json")).unwrap();
        doc["config"]["rollupX"] = serde_json::to_value(DerivationConfig {
            fee_collector: alloy_primitives::address!("f39fd6e51aad88f6f4ce6ab8827279cfffb92266"),
            history_update_offset: 0,
            block_interval_seconds: 1,
            sync_interval_blocks: 5,
            l1_reference: GenesisL1Reference {
                chain_id: 10200,
                number: 123,
                hash: B256::with_last_byte(1),
                timestamp: 1000,
                prev_randao: B256::with_last_byte(2),
            },
        })
        .unwrap();
        doc
    }

    #[test]
    fn complete_source_identity_retains_checked_extension_and_l1_schema_is_separate() {
        let doc = document();
        let encoded = serde_json::to_vec(&doc).unwrap();
        let loaded = parse_l2_genesis(&encoded).unwrap();
        assert_eq!(
            loaded.digest(),
            keccak256(canonicalize_chain_json(&encoded).unwrap())
        );
        assert_eq!(loaded.derivation().sync_interval_blocks, 5);
        assert_eq!(
            loaded.into_genesis().config.extra_fields["rollupX"],
            doc["config"]["rollupX"]
        );
        assert!(
            parse_chain_document_with_digest(&encoded).is_err(),
            "L1 must not inherit this namespace"
        );
        let mut changed = doc;
        changed["config"]["rollupX"]["l1Reference"]["number"] = 124.into();
        let other = parse_l2_genesis(&serde_json::to_vec(&changed).unwrap()).unwrap();
        assert_ne!(
            other.digest(),
            keccak256(canonicalize_chain_json(&encoded).unwrap())
        );
    }

    #[test]
    fn malformed_unknown_missing_and_duplicate_values_are_never_normalized() {
        let mutations: &[fn(&mut serde_json::Value)] = &[
            |v| {
                v["config"].as_object_mut().unwrap().remove("rollupX");
            },
            |v| v["config"]["rollupX"] = serde_json::Value::Null,
            |v| v["config"]["rollupX"]["syncIntervalBlocks"] = (-1).into(),
            |v| v["config"]["rollupX"]["blockIntervalSeconds"] = "1".into(),
            |v| v["config"]["rollupX"]["l1Reference"]["hash"] = "0x12".into(),
            |v| v["config"]["rollupX"]["l1Reference"]["finalized"] = true.into(),
            |v| v["config"]["rollupX"]["blockIntervaSeconds"] = 1.into(),
            |v| v["config"]["osakaTiem"] = 0.into(),
            |v| v["unsupportedGenesisField"] = 0.into(),
        ];
        for mutate in mutations {
            let mut doc = document();
            mutate(&mut doc);
            assert!(
                parse_l2_genesis(&serde_json::to_vec(&doc).unwrap()).is_err(),
                "{doc}"
            );
        }
        let encoded = serde_json::to_string(&document()).unwrap();
        for duplicate in [
            "\"syncIntervalBlocks\":5,\"syncIntervalBlocks\":5",
            "\"syncIntervalBlocks\":5,\"syncInterval\\u0042locks\":5",
        ] {
            let invalid = encoded.replace("\"syncIntervalBlocks\":5", duplicate);
            assert!(
                parse_l2_genesis(invalid.as_bytes())
                    .unwrap_err()
                    .to_string()
                    .contains("duplicate")
            );
        }
        assert!(parse_l2_genesis(br#"{"chainId":1}"#).is_err());
    }

    fn hydration_document() -> serde_json::Value {
        let mut doc = document();
        doc["config"]["hydration"] = serde_json::json!({
            "rulesVersion": 1,
            "oracleUpdater": "0x00000000000000000000000000000000000000a1",
            "peplKeeper": "0x00000000000000000000000000000000000000b2",
        });
        doc
    }

    #[test]
    fn hydration_section_is_checked_retained_unchanged_and_digested() {
        let doc = hydration_document();
        let encoded = serde_json::to_vec(&doc).unwrap();
        let loaded = parse_l2_genesis(&encoded).unwrap();
        assert_eq!(
            loaded.digest(),
            keccak256(canonicalize_chain_json(&encoded).unwrap())
        );
        assert_ne!(
            loaded.digest(),
            parse_l2_genesis(&serde_json::to_vec(&document()).unwrap())
                .unwrap()
                .digest(),
            "the section must change the document digest"
        );
        let mut changed = doc.clone();
        changed["config"]["hydration"]["peplKeeper"] =
            "0x00000000000000000000000000000000000000b3".into();
        assert_ne!(
            parse_l2_genesis(&serde_json::to_vec(&changed).unwrap())
                .unwrap()
                .digest(),
            loaded.digest(),
            "a role change must change the document digest"
        );
        let genesis = loaded.into_genesis();
        assert_eq!(
            genesis.config.extra_fields[hydration_config::GENESIS_FIELD],
            doc["config"]["hydration"]
        );
        assert_eq!(
            genesis.config.extra_fields["rollupX"],
            doc["config"]["rollupX"]
        );
        assert!(
            parse_chain_document_with_digest(&encoded).is_err(),
            "L1 must not inherit this namespace"
        );
        // The retained section is what the rollup execution layer decodes.
        let hydration =
            eez_evm::profile::hydration(&reth_chainspec::ChainSpec::from_genesis(genesis))
                .unwrap()
                .unwrap();
        assert_eq!(
            (hydration.oracle_updater(), hydration.pepl_keeper()),
            (
                alloy_primitives::address!("00000000000000000000000000000000000000a1"),
                alloy_primitives::address!("00000000000000000000000000000000000000b2"),
            )
        );
    }

    #[test]
    fn malformed_or_invalid_hydration_sections_are_rejected_with_their_reason() {
        let cases: &[(fn(&mut serde_json::Value), &str)] = &[
            (
                |v| v["config"]["hydration"] = serde_json::Value::Null,
                "malformed config.hydration",
            ),
            (
                |v| v["config"]["hydration"]["unknown"] = true.into(),
                "unknown field `unknown`",
            ),
            (
                |v| {
                    v["config"]["hydration"]
                        .as_object_mut()
                        .unwrap()
                        .remove("peplKeeper");
                },
                "missing field `peplKeeper`",
            ),
            (
                |v| v["config"]["hydration"]["rulesVersion"] = "1".into(),
                "malformed config.hydration",
            ),
            (
                |v| v["config"]["hydration"]["rulesVersion"] = 2.into(),
                "unsupported config.hydration rulesVersion",
            ),
            (
                |v| {
                    v["config"]["hydration"]["oracleUpdater"] =
                        serde_json::json!(alloy_primitives::Address::ZERO);
                },
                "config.hydration oracleUpdater is the zero address",
            ),
            (
                |v| {
                    v["config"]["hydration"]["peplKeeper"] =
                        serde_json::json!(alloy_primitives::Address::ZERO);
                },
                "config.hydration peplKeeper is the zero address",
            ),
            (
                |v| {
                    v["config"]["hydration"]["peplKeeper"] =
                        v["config"]["hydration"]["oracleUpdater"].clone();
                },
                "oracleUpdater and peplKeeper are the same account",
            ),
            (
                |v| {
                    let section = v["config"]
                        .as_object_mut()
                        .unwrap()
                        .remove("hydration")
                        .unwrap();
                    v["config"]["hydrationn"] = section;
                },
                "unsupported fields: `hydrationn`",
            ),
        ];
        parse_l2_genesis(&serde_json::to_vec(&hydration_document()).unwrap()).unwrap();
        for (mutate, reason) in cases {
            let mut doc = hydration_document();
            mutate(&mut doc);
            let error = parse_l2_genesis(&serde_json::to_vec(&doc).unwrap()).unwrap_err();
            assert!(format!("{error:#}").contains(reason), "{reason}: {error:#}");
        }
    }
}
