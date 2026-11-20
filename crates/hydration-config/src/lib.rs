//! Hydration's optional L2 genesis section, `config.hydration`.
//!
//! The section sits beside `config.rollupX` in the L2 genesis document and switches
//! on every Hydration rule for that network at once:
//!
//! - the counter precompile at [`COUNTER_ADDRESS`], on the rollup execution layer
//!   only (L1 simulation never reads the section);
//! - the protocol-transaction ordering prefix: the oracle updater's oracle-update
//!   transaction, then the PEPL keeper's transaction, directly after EEZ's optional
//!   leading `0x46` history transaction.
//!
//! A chain without the section runs RollupX's stock rules unchanged. There is no
//! activation height and no default: a different section is a different genesis
//! document, and so a different validation-identity digest.
//!
//! The section is not bound on chain. Its required alloc seed (see
//! [`HydrationConfig::check_counter_seed`]) changes the genesis hash, but the same
//! seed without the section gives the same hash while running stock rules.
//!
//! This crate only decodes and checks the section. It depends on serde and
//! alloy-primitives alone, so a genesis loader can reject a malformed section
//! without linking an EVM or the precompile.

#![cfg_attr(not(test), no_std)]

use alloy_primitives::{Address, U256, address};
use core::fmt;
use serde::{Deserialize, Deserializer, Serialize};

/// Key of the section inside the genesis `config` object, a sibling of `rollupX`.
pub const GENESIS_FIELD: &str = "hydration";

/// The only defined `rulesVersion`: the counter precompile plus the ordering prefix.
pub const RULES_VERSION_1: u64 = 1;

/// Hydration's counter precompile (rules version 1). Outside Ethereum's precompile range.
pub const COUNTER_ADDRESS: Address = address!("0x0000000000000000000000000000000000000800");

/// Exact wire form. Every field is required and unknown fields are rejected, so a
/// misspelled or extra key cannot be silently dropped from the active rules.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireConfig {
    rules_version: u64,
    #[serde(deserialize_with = "deserialize_hex_address")]
    oracle_updater: Address,
    #[serde(deserialize_with = "deserialize_hex_address")]
    pepl_keeper: Address,
}

/// Accept only a `0x`-prefixed string of 40 hex digits (either case). Alloy's own
/// `Address` decoding also takes an unprefixed string or a byte array.
fn deserialize_hex_address<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> Result<Address, D::Error> {
    struct HexAddress;
    impl serde::de::Visitor<'_> for HexAddress {
        type Value = Address;
        fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str("a 0x-prefixed 20-byte hex address")
        }
        fn visit_str<E: serde::de::Error>(self, value: &str) -> Result<Address, E> {
            value
                .strip_prefix("0x")
                .filter(|digits| digits.len() == 40)
                .and_then(|_| value.parse().ok())
                .ok_or_else(|| E::invalid_value(serde::de::Unexpected::Str(value), &self))
        }
    }
    deserializer.deserialize_str(HexAddress)
}

impl WireConfig {
    /// Accept only an object. Derived struct decoding would also accept a positional
    /// array (`[1, "0x..", "0x.."]`), a second spelling of the same section.
    fn deserialize_object<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ObjectOnly;
        impl<'de> serde::de::Visitor<'de> for ObjectOnly {
            type Value = WireConfig;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("a config.hydration object")
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                map: A,
            ) -> Result<WireConfig, A::Error> {
                WireConfig::deserialize(serde::de::value::MapAccessDeserializer::new(map))
            }
        }
        deserializer.deserialize_map(ObjectOnly)
    }
}

/// A checked `config.hydration` section.
///
/// Every value satisfies [`HydrationConfig::new`]'s rules, whether it was
/// constructed or decoded: the [`Deserialize`] implementation runs the same checks.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HydrationConfig {
    rules_version: u64,
    oracle_updater: Address,
    pepl_keeper: Address,
}

impl HydrationConfig {
    /// Check a section's values.
    ///
    /// # Errors
    ///
    /// Rejects any `rules_version` other than [`RULES_VERSION_1`], a zero role
    /// address, and an oracle updater that is also the PEPL keeper (the ordering
    /// prefix classifies a transaction by its sender, so one account cannot hold both).
    pub fn new(
        rules_version: u64,
        oracle_updater: Address,
        pepl_keeper: Address,
    ) -> Result<Self, HydrationConfigError> {
        if rules_version != RULES_VERSION_1 {
            return Err(HydrationConfigError::UnsupportedRulesVersion);
        }
        if oracle_updater.is_zero() {
            return Err(HydrationConfigError::ZeroOracleUpdater);
        }
        if pepl_keeper.is_zero() {
            return Err(HydrationConfigError::ZeroPeplKeeper);
        }
        if oracle_updater == pepl_keeper {
            return Err(HydrationConfigError::OracleUpdaterIsPeplKeeper);
        }
        Ok(Self {
            rules_version,
            oracle_updater,
            pepl_keeper,
        })
    }

    /// Decode and check one section value, such as a `&serde_json::Value`.
    ///
    /// # Errors
    ///
    /// [`SectionError::Malformed`] for a value that is not exactly the wire object
    /// (`null`, a missing, unknown or mistyped field); [`SectionError::Invalid`] for
    /// a well-formed object that [`HydrationConfig::new`] rejects.
    pub fn decode<'de, D: Deserializer<'de>>(section: D) -> Result<Self, SectionError<D::Error>> {
        let wire = WireConfig::deserialize_object(section).map_err(SectionError::Malformed)?;
        Self::new(wire.rules_version, wire.oracle_updater, wire.pepl_keeper)
            .map_err(SectionError::Invalid)
    }

    /// Decode the optional section as found in a genesis `config` object, for example
    /// `genesis.config.extra_fields.get(GENESIS_FIELD)`.
    ///
    /// `Ok(None)` means the section is absent and the chain runs stock RollupX rules.
    /// A present `null` is malformed, not absent.
    ///
    /// # Errors
    ///
    /// As [`HydrationConfig::decode`].
    pub fn from_genesis_section<'de, D: Deserializer<'de>>(
        section: Option<D>,
    ) -> Result<Option<Self>, SectionError<D::Error>> {
        section.map(Self::decode).transpose()
    }

    /// Check the genesis alloc entry at [`COUNTER_ADDRESS`].
    ///
    /// Rules version 1 requires it with nonce 1 and nothing else. The counter writes
    /// storage, and EIP-161 treats an account with zero nonce, zero balance and no
    /// code as empty, whatever its storage; seeding nonce 1 keeps the account
    /// non-empty from block 0. Balance, code or storage would give the precompile
    /// address state that its rules do not define.
    ///
    /// # Errors
    ///
    /// [`HydrationConfigError::MissingCounterSeed`] when the entry is absent,
    /// [`HydrationConfigError::InvalidCounterSeed`] when it is anything but nonce 1.
    pub fn check_counter_seed(
        &self,
        account: Option<SeedAccount>,
    ) -> Result<(), HydrationConfigError> {
        let account = account.ok_or(HydrationConfigError::MissingCounterSeed)?;
        if account.nonce != Some(1)
            || !account.balance.is_zero()
            || account.has_code
            || account.has_storage
        {
            return Err(HydrationConfigError::InvalidCounterSeed);
        }
        Ok(())
    }

    /// Always [`RULES_VERSION_1`].
    pub const fn rules_version(&self) -> u64 {
        self.rules_version
    }

    /// The only sender whose oracle-update transaction fills the first prefix slot.
    pub const fn oracle_updater(&self) -> Address {
        self.oracle_updater
    }

    /// The only sender whose transaction fills the second prefix slot.
    pub const fn pepl_keeper(&self) -> Address {
        self.pepl_keeper
    }
}

impl<'de> Deserialize<'de> for HydrationConfig {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let wire = WireConfig::deserialize_object(deserializer)?;
        Self::new(wire.rules_version, wire.oracle_updater, wire.pepl_keeper)
            .map_err(serde::de::Error::custom)
    }
}

/// A genesis alloc entry reduced to the fields that determine its account state.
///
/// This keeps the crate free of genesis types; callers map their alloc
/// representation. An empty code or storage field is the same state as an absent one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SeedAccount {
    /// `None` when the entry omits its nonce, which means nonce 0.
    pub nonce: Option<u64>,
    pub balance: U256,
    /// Non-empty code.
    pub has_code: bool,
    /// At least one storage entry, including an explicit zero value.
    pub has_storage: bool,
}

/// A well-formed section or genesis that breaks a Hydration rule.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HydrationConfigError {
    UnsupportedRulesVersion,
    ZeroOracleUpdater,
    ZeroPeplKeeper,
    OracleUpdaterIsPeplKeeper,
    MissingCounterSeed,
    InvalidCounterSeed,
}

impl HydrationConfigError {
    /// A fixed description, for callers whose error type carries only static text.
    pub const fn reason(self) -> &'static str {
        match self {
            Self::UnsupportedRulesVersion => "unsupported config.hydration rulesVersion",
            Self::ZeroOracleUpdater => "config.hydration oracleUpdater is the zero address",
            Self::ZeroPeplKeeper => "config.hydration peplKeeper is the zero address",
            Self::OracleUpdaterIsPeplKeeper => {
                "config.hydration oracleUpdater and peplKeeper are the same account"
            }
            Self::MissingCounterSeed => {
                "config.hydration requires alloc 0x..0800 with nonce 1 and nothing else"
            }
            Self::InvalidCounterSeed => {
                "config.hydration alloc 0x..0800 must have nonce 1 and no code, balance or storage"
            }
        }
    }
}

impl fmt::Display for HydrationConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.reason())
    }
}

impl core::error::Error for HydrationConfigError {}

/// Why a present section was rejected.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SectionError<E> {
    /// Not exactly the wire object; carries the decoder's error.
    Malformed(E),
    /// Well-formed, but its values break a rule.
    Invalid(HydrationConfigError),
}

impl<E> SectionError<E> {
    /// A fixed description, for callers whose error type carries only static text.
    /// Drops the decoder's detail for [`SectionError::Malformed`].
    pub const fn reason(&self) -> &'static str {
        match self {
            Self::Malformed(_) => "malformed config.hydration",
            Self::Invalid(error) => error.reason(),
        }
    }
}

impl<E: fmt::Display> fmt::Display for SectionError<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Malformed(error) => write!(f, "malformed config.hydration: {error}"),
            Self::Invalid(error) => fmt::Display::fmt(error, f),
        }
    }
}

impl<E: fmt::Debug + fmt::Display> core::error::Error for SectionError<E> {}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    const ORACLE: Address = address!("0x00000000000000000000000000000000000000a1");
    const KEEPER: Address = address!("0x00000000000000000000000000000000000000b2");

    fn section() -> Value {
        json!({ "rulesVersion": 1, "oracleUpdater": ORACLE, "peplKeeper": KEEPER })
    }

    fn seed() -> SeedAccount {
        SeedAccount {
            nonce: Some(1),
            balance: U256::ZERO,
            has_code: false,
            has_storage: false,
        }
    }

    #[test]
    fn well_formed_section_decodes_round_trips_and_exposes_roles() {
        let config = HydrationConfig::decode(&section()).unwrap();
        assert_eq!(config.rules_version(), RULES_VERSION_1);
        assert_eq!(config.oracle_updater(), ORACLE);
        assert_eq!(config.pepl_keeper(), KEEPER);
        assert_eq!(serde_json::to_value(config).unwrap(), section());
        assert_eq!(
            serde_json::from_value::<HydrationConfig>(section()).unwrap(),
            config
        );
        assert_eq!(
            HydrationConfig::from_genesis_section(Some(&section())).unwrap(),
            Some(config)
        );
        assert_eq!(
            HydrationConfig::from_genesis_section(None::<&Value>).unwrap(),
            None
        );
        // Hex digits in either case (for example an EIP-55 checksum) are one address.
        let mut upper = section();
        upper["peplKeeper"] = json!("0x00000000000000000000000000000000000000B2");
        assert_eq!(HydrationConfig::decode(&upper).unwrap(), config);
    }

    #[test]
    fn malformed_sections_are_rejected_not_normalized() {
        let mutations: &[fn(&mut Value)] = &[
            |v| *v = Value::Null,
            |v| *v = json!({}),
            |v| *v = json!([1, ORACLE, KEEPER]),
            |v| v["rulesVersion"] = json!("1"),
            |v| v["rulesVersion"] = json!(1.0),
            |v| v["rulesVersion"] = json!(-1),
            |v| v["rulesVersion"] = Value::Null,
            |v| v["oracleUpdater"] = json!("0x12"),
            |v| v["oracleUpdater"] = json!("00000000000000000000000000000000000000a1"),
            |v| v["oracleUpdater"] = json!("0X00000000000000000000000000000000000000a1"),
            |v| v["oracleUpdater"] = json!("0x00000000000000000000000000000000000000g1"),
            |v| v["oracleUpdater"] = json!("0x0000000000000000000000000000000000000000a1"),
            |v| v["oracleUpdater"] = json!(ORACLE.0.0),
            |v| v["peplKeeper"] = Value::Null,
            |v| v["unknown"] = json!(true),
            |v| {
                v.as_object_mut().unwrap().remove("rulesVersion");
            },
            |v| {
                v.as_object_mut().unwrap().remove("oracleUpdater");
            },
            |v| {
                v.as_object_mut().unwrap().remove("peplKeeper");
            },
            |v| {
                let keeper = v.as_object_mut().unwrap().remove("peplKeeper").unwrap();
                v["pepl_keeper"] = keeper;
            },
        ];
        for mutate in mutations {
            let mut value = section();
            mutate(&mut value);
            assert!(
                matches!(
                    HydrationConfig::decode(&value),
                    Err(SectionError::Malformed(_))
                ),
                "{value}"
            );
            assert!(serde_json::from_value::<HydrationConfig>(value).is_err());
        }
        // Present but null is malformed, not absent.
        assert!(matches!(
            HydrationConfig::from_genesis_section(Some(&Value::Null)),
            Err(SectionError::Malformed(_))
        ));
    }

    #[test]
    fn well_formed_sections_that_break_a_rule_are_rejected_with_their_reason() {
        let cases = [
            (
                json!({ "rulesVersion": 0, "oracleUpdater": ORACLE, "peplKeeper": KEEPER }),
                HydrationConfigError::UnsupportedRulesVersion,
            ),
            (
                json!({ "rulesVersion": 2, "oracleUpdater": ORACLE, "peplKeeper": KEEPER }),
                HydrationConfigError::UnsupportedRulesVersion,
            ),
            (
                json!({ "rulesVersion": 1, "oracleUpdater": Address::ZERO, "peplKeeper": KEEPER }),
                HydrationConfigError::ZeroOracleUpdater,
            ),
            (
                json!({ "rulesVersion": 1, "oracleUpdater": ORACLE, "peplKeeper": Address::ZERO }),
                HydrationConfigError::ZeroPeplKeeper,
            ),
            (
                json!({ "rulesVersion": 1, "oracleUpdater": ORACLE, "peplKeeper": ORACLE }),
                HydrationConfigError::OracleUpdaterIsPeplKeeper,
            ),
        ];
        for (value, expected) in cases {
            assert!(
                matches!(
                    HydrationConfig::decode(&value),
                    Err(SectionError::Invalid(error)) if error == expected
                ),
                "{value}"
            );
            let error = serde_json::from_value::<HydrationConfig>(value).unwrap_err();
            assert!(error.to_string().contains(expected.reason()), "{error}");
        }
    }

    #[test]
    fn counter_seed_must_be_nonce_one_and_nothing_else() {
        let config = HydrationConfig::decode(&section()).unwrap();
        config.check_counter_seed(Some(seed())).unwrap();
        assert_eq!(
            config.check_counter_seed(None),
            Err(HydrationConfigError::MissingCounterSeed)
        );
        for invalid in [
            SeedAccount {
                nonce: None,
                ..seed()
            },
            SeedAccount {
                nonce: Some(0),
                ..seed()
            },
            SeedAccount {
                nonce: Some(2),
                ..seed()
            },
            SeedAccount {
                balance: U256::from(1),
                ..seed()
            },
            SeedAccount {
                has_code: true,
                ..seed()
            },
            SeedAccount {
                has_storage: true,
                ..seed()
            },
        ] {
            assert_eq!(
                config.check_counter_seed(Some(invalid)),
                Err(HydrationConfigError::InvalidCounterSeed),
                "{invalid:?}"
            );
        }
    }
}
