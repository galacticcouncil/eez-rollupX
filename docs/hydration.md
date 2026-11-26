# Hydration customization inventory

This document is the authoritative inventory of Hydration-specific behavior
added to the RollupX fork. It describes the overlay introduced by the
`hydration-evm` branch over fork `main`, not every historical difference between
RollupX and `eez-association/eez-rollup0`.

Update this document whenever a change adds, removes, or changes Hydration
behavior, its activation contract, compatibility boundary, operational setup, or
validation. Keep general RollupX behavior in its owning specification or runbook.

## Provenance snapshot

| Item | Revision |
| --- | --- |
| Fork baseline (`main`) | `81404f15e57c699c398538b54447817774c70c1f` |
| Hydration overlay | `d4a9e90f8e0dd98a8d871b5ca697da540e0202ea` |
| Overlay commits | `72336e0634543f944e3086712efd2f17a526137f`, `d4a9e90f8e0dd98a8d871b5ca697da540e0202ea` |
| Pinned core protocol | `84a5b5207880f192a6a5896cbfe0bac5249db47f` |
| Reproducible comparison | `git diff --find-renames 81404f15e57c699c398538b54447817774c70c1f...d4a9e90f8e0dd98a8d871b5ca697da540e0202ea` |

The snapshot identifies the introduction range. After the overlay merges, use
this inventory and file history rather than assuming that `main...HEAD` still
represents the Hydration boundary.

## Activation and compatibility contract

Hydration behavior is enabled only when the L2 genesis contains a valid
`config.hydration` object. Rules version 1 requires distinct, nonzero
`oracleUpdater` and `peplKeeper` addresses and a counter account at
`0x0000000000000000000000000000000000000800` seeded with nonce 1 and no balance,
code, or storage. A missing section preserves stock RollupX behavior. A present
but malformed or unsupported section fails validation; it is never treated as
absent.

The section is part of the canonical chain document and its validation-identity
digest. It therefore defines a fresh-network consensus profile, not a per-node
runtime option or an activation-height upgrade. Every L2 executor, importer,
payload builder, follower, and proof signer must use the same genesis document.
L1 simulations retain stock precompiles.

## Feature inventory

For an introductory walkthrough, see the
[block production and settlement lifecycle](hydration/block-production-lifecycle.md).

| ID | Status | Customization | Owning implementation |
| --- | --- | --- | --- |
| HYD-01 | Active when configured | Strictly decode `config.hydration`, validate rules version 1 and role identities, validate the counter seed, retain the section in canonical genesis handling, and expose the checked configuration from the L2 chain specification. | `hydration-config`; `eez-l1::chain_config`; `eez-evm::profile` |
| HYD-02 | Active when configured | Classify oracle price updates and PEPL keeper transactions by genesis-bound roles. A valid block prefix is `[EEZ history 0x46?][oracle update?][keeper?][ordinary...]`. A configured role transaction outside its reserved position invalidates the block. | `hydration-consensus-rules`; `hydration-node` |
| HYD-03 | Active when configured | Reorder at most one oracle update and one keeper transaction from the L2 mempool into the Live-block prefix. Later role transactions stay pending. Reject configured L2 protocol transactions at outbound cross-chain fronts because a Sync block cannot place them in the prefix. | `hydration-node`; `eez-node-common::payload`; `eez-node::ingress` |
| HYD-04 | Active when configured | Apply the same prefix validation during node import and independent proof-signer replay. This supplements, but does not replace, transaction decoding, signer recovery, execution validation, or EEZ native-transaction checks. | `hydration-node::HydrationConsensus`; `eez-node`; `eez-proof-signer` |
| HYD-05 | Active when configured | Install a stateful counter precompile at `0x...0800` on every L2 EVM path. `get()` is static-safe; `increment()` charges before mutation, saturates at `uint256::MAX`, rejects static and delegated calls, and preserves the nonce that prevents EIP-161 account deletion. The address must not use a precompile result cache. | `hydration-precompiles`; `eez-evm::EezEvmFactory` |
| HYD-06 | Supporting integration | Share checked roles and rule helpers without coupling portable consensus code to Reth or the EVM. Extend testkit builders and process tests so stock and Hydration profiles exercise payload construction, import, signer rejection, history-prefix interaction, counter state, and cross-chain admission. | Four `hydration-*` crates; `eez-testkit`; `eez-node-e2e` |
| HYD-07 | Adapter present; not production-wired | Provide a ZisK proof-system adapter that binds schema, public-input hash, program verification key, rollup ID, manager registration, and the external ZisK verifier call. The branch does not wire a real Hydration-aware guest/prover or a production deployment path. | `contracts/src/zisk`; `contracts/test/zisk` |
| HYD-08 | Test-only | Provide `CounterRelay` for process-test calls and `MockZiskVerifier` for adapter tests. Neither contract is a production authorization or proof system. | `contracts/src/CounterRelay.sol`; `contracts/src/zisk/MockZiskVerifier.sol` |
| HYD-09 | Supporting tooling and operations | Include the Hydration process-test binary in native artifact inventories; document the optional genesis section and seed in the Chiado deployment runbook and the [local Swarm profile](hydration/local-devnet.md). Local public-fixture counter execution and ECDSA settlement were validated at Rust revision `5f8813d4`; broader qualification remains separate. | `scripts/ci/native-tests.py`; `scripts/ci/tests/test_native_artifacts.py`; `docs/runbooks/chiado-deployment.md`; `deploy/swarm/devnet/l2-deploy.sh` |

## Consensus and execution invariants

- The genesis section is the single switch for all Hydration rules. Callers must
  not enable the counter, prefix ordering, import validation, or signer validation
  independently.
- Only one leading EEZ history transaction of type `0x46` is skipped before the
  Hydration prefix. Cross-chain type `0x45` is ordinary for this rule.
- Role classification uses recovered senders and the exact oracle selectors
  `setAssetPrice(address,uint256)` and `setAssetPrices(address[],uint256[])`.
  Every keeper transaction is a protocol transaction.
- Protocol transactions must enter through the L2 mempool. Cross-chain holding,
  native grouping, callbacks, or replay must not create another placement path.
- Every L2 execution path must construct its EVM through `EezEvmConfig::new` and
  the rollup-layer `EezEvmFactory`; otherwise the counter address behaves as an
  empty account and consensus diverges.
- The proof signer independently reconstructs the roles from its admitted chain
  document and rejects misplaced protocol transactions before execution.
- Portable legacy-role helpers remain for Hydreth, the existing ZisK guest, and
  eez-rollup0 compatibility. RollupX consensus paths use the genesis-bound
  `*_with_roles` APIs.
- The Core Rollup contract, ABI, public inputs, and pinned protocol revision are
  unchanged by this overlay.

## Complete introduction-path manifest

The introduction range changes 48 paths. This manifest is a provenance aid, not
an ownership substitute: the feature table and the nearest specifications remain
authoritative for behavior.

### Workspace and instructions

- `AGENTS.md`
- `Cargo.toml`
- `Cargo.lock`

### Solidity adapter and fixtures

- `contracts/src/CounterRelay.sol`
- `contracts/src/zisk/IZiskVerifier.sol`
- `contracts/src/zisk/MockZiskVerifier.sol`
- `contracts/src/zisk/ZiskProofSystem.sol`
- `contracts/test/fixtures/README.md`
- `contracts/test/fixtures/zisk/golden_pv_schema1_h11_vk22_rid7.hex`
- `contracts/test/zisk/GoldenVector.t.sol`
- `contracts/test/zisk/ZiskProofSystem.t.sol`

### RollupX execution integration

- `crates/eez-evm/Cargo.toml`
- `crates/eez-evm/src/block.rs`
- `crates/eez-evm/src/evm.rs`
- `crates/eez-evm/src/evm/tests.rs`
- `crates/eez-evm/src/profile.rs`
- `crates/eez-evm/src/reth211_tests.rs`
- `crates/eez-evm/src/reth211_tests/replay.rs`
- `crates/eez-evm/src/tests.rs`
- `crates/eez-l1/Cargo.toml`
- `crates/eez-l1/src/chain_config/l2.rs`
- `crates/eez-node-common/Cargo.toml`
- `crates/eez-node-common/src/node.rs`
- `crates/eez-node-common/src/payload.rs`
- `crates/eez-node-common/src/payload_builder/tests.rs`
- `crates/eez-node/Cargo.toml`
- `crates/eez-node/src/ingress.rs`
- `crates/eez-node/src/lib.rs`
- `crates/eez-proof-signer/Cargo.toml`
- `crates/eez-proof-signer/SPEC.md`
- `crates/eez-proof-signer/src/validate/stateless.rs`
- `crates/eez-proof-signer/src/validate/stateless/tests.rs`

### Hydration crates and process coverage

- `crates/hydration-config/Cargo.toml`
- `crates/hydration-config/src/lib.rs`
- `crates/hydration-consensus-rules/Cargo.toml`
- `crates/hydration-consensus-rules/src/lib.rs`
- `crates/hydration-node/Cargo.toml`
- `crates/hydration-node/src/lib.rs`
- `crates/hydration-precompiles/Cargo.toml`
- `crates/hydration-precompiles/src/lib.rs`
- `crates/eez-testkit/Cargo.toml`
- `crates/eez-testkit/src/lib.rs`
- `crates/eez-node-e2e/Cargo.toml`
- `crates/eez-node-e2e/tests/hydration.rs`
- `crates/eez-node-e2e/tests/main.rs`

### Operations and CI inventory

- `docs/runbooks/chiado-deployment.md`
- `scripts/ci/native-tests.py`
- `scripts/ci/tests/test_native_artifacts.py`

## Validation snapshot

The introduction range was independently reviewed and then checked with a
one-pass `solidity-auditor` 4.1 run. Both reported zero confirmed High, Medium,
or Low findings. The following local checks passed at
`d4a9e90f8e0dd98a8d871b5ca697da540e0202ea`:

- 38 tests across `hydration-config`, `hydration-consensus-rules`,
  `hydration-precompiles`, and `hydration-node`;
- 80 `eez-evm`, 213 `eez-l1`, and 20 `eez-node-common` library tests;
- Rust formatting and diff-hygiene checks;
- 44 native-artifact inventory tests, with one explicit opt-in test skipped.

Foundry tests, signer and broader node suites, Hydration process tests, full
Clippy/workspace checks, Kurtosis, live-network validation, and a real ZisK proof
path were not completed in that review environment. Do not treat this inventory
or the recorded checks as proof of deployment readiness.

## Maintenance checklist

When the Hydration overlay changes:

1. Update the relevant feature row, status, invariants, and owning paths here.
2. Update the owning specification or runbook when wire, consensus,
   configuration, storage, deployment, or mixed-version behavior changes.
3. Add new introduction or follow-up paths to the manifest; do not remove
   historical introduction paths merely because code later moves.
4. Record the change's revisions and validation in the applicable task note or
   audit record. Keep detailed test evidence there rather than growing this
   inventory into a chronological log.
