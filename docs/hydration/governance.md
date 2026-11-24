# Hydration governance PoC

Opt-in port to branch `gov` at target baseline `9666c539`, with pinned Core
`84a5b5207880f192a6a5896cbfe0bac5249db47f`. Source: the original
`../eez-rollup0` `runtime_upgrades` checkpoint `2858f7e`, including local
reader/context follow-up work. See the [port inventory and compatibility boundaries](governance-port.md).

This is authorization/rehearsal tooling, not enabled production governance or
an on-chain executable runtime. The Core pin, genesis, native operations,
validation identity, registered keys, evm2 engine, and offline signer are unchanged.

## Components

- [UpgradeController](../../contracts/src/governance/UpgradeController.sol): the authority queues
  an exact call hash; after an immutable L1-time delay anyone can execute the
  matching calldata within its expiry window. Epoch/nonces, cancellation,
  domain binding, target-code checks and an execution reentrancy guard apply.
  Failed target calls revert the execution and leave the operation retryable.
- [AuthorityRegistry](../../contracts/src/governance/AuthorityRegistry.sol): stores the current
  authority/domain/epoch. Rotation goes through the same timelock, retires old
  authorities/departed domains and invalidates old-epoch queued operations.
  An address/domain is not proof of an OpenGov decision; authentication adapters
  and native voting are not implemented.
- [ExecutionUpgradeSchedule](../../contracts/src/governance/ExecutionUpgradeSchedule.sol): records
  predecessor, release/node/guest/program-key hashes and increasing L2 activation
  heights. Genesis release ID is 0; successors increment by one. One future tail
  may be cancelled; activated history stays. This records intent, not proof
  selection, software installation or a production fork schedule.
- [hydration-governance](../../crates/hydration-governance/src/lib.rs): isolated
  administrative reader and engine-neutral rehearsal model. No shipping runtime
  depends on it. No signer RPC source, background task or startup flag is added.

The controller operation hash binds its exact fields to the L1 chain, controller,
EEZ registry and rollup. Use `hashOperation` for canonical encoding. The release
descriptor similarly binds its deployment/L2 genesis/grid and activation through
`hashUpgrade`. Controller timestamps are L1 seconds, not L2 heights.

## Local validation and rehearsal

Use Rust 1.96.0 and Foundry 1.7.1, with the pinned protocol initialized. From the
repository root:

```sh
cargo +1.96.0 test --locked -p hydration-governance --all-targets
forge test --root contracts --match-contract 'UpgradeControllerTest|ExecutionUpgradeScheduleTest|DeployUpgradeControllerTest|DeployRuntimeGovernanceTest|GovernanceProxyIntegrationTest'
forge script --root contracts contracts/script/RehearseGovernance.s.sol:RehearseGovernance
forge script --root contracts contracts/script/RehearseExecutionUpgrade.s.sol:RehearseExecutionUpgrade
```

The scripts run in local Foundry simulation without RPC, funded accounts or
broadcast. They use the pinned real registry/manager proxies, with the original
four-argument manager initializer and registration by its owner. Hashes and keys
are fixtures, not published artifacts or deployed network-profile keys. The
execution rehearsal asserts schedule metadata at A-1/A; it does not run an evm2
runtime switch, change the manager's key, or verify a ZisK proof.

## Fresh-devnet operational handoff (optional)

This is not part of normal deployment/startup. For operator prerequisites and
network compatibility, first read the [deployment runbook](../runbooks/chiado-deployment.md),
especially [manager/key coordination](../runbooks/chiado-deployment.md#rollup-manager-and-coordinated-upgrades).
Do not use the PoC to migrate an old network into the offline profile.

The existing registered manager must be the pinned Core proxy, initialized and
owned by the broadcasting account. `DeployUpgradeController` checks registration
and current ownership before deploying/handoff. `DeployRuntimeGovernance` adds
the metadata schedule before handoff; it also requires a usable cancellation
response margin. Both use `EEZContract()`, not the old `ROLLUPS()` getter.

`scripts/deploy-runtime-governance.sh` is an explicit follow-on to a normal
fresh deployment. It defaults to simulation, requires an external Foundry signer,
refuses raw-key/mnemonic options and existing pins output, checks L1/rollup/timing,
and derives the actual rendered genesis header identity through the governance
`genesis_identity` example, using the same pinned ChainSpec as the node. The helper does not compute or replace the registered
network vkey. After an intentional broadcast it checks operational ownership and
writes public reader pins with observed controller/schedule code hashes. Review
those hashes against the build. No node configuration is enabled or changed.

The public CONFIG JSON contains `l1_chain_id`, `manager`, `eez_registry`,
`rollup_id`, `authority`, nonzero bytes32 `source_domain`, `min_delay`,
`l2_block_seconds`, `min_notice`, `cancel_notice`, and `genesis_release`:
`runtimeVersion` (0), `releaseHash`, `nodeArtifactHash`, `guestArtifactHash`,
`programVKey` (zero is permitted for the ECDSA rehearsal). Optional
`supported_releases` is the local reviewed compatibility list, defaulting to
genesis only; `max_entries` defaults to 100. Hash fields are bytes32. No keys,
authenticated URLs or operator state belong in this JSON or source control.

Example invocation, after preparing the actual public config and rendered genesis:

```sh
# Set EEZ_L1_RPC_URL and the actual EEZ_L2_BLOCK_TIME_MS in this shell.
bash scripts/deploy-runtime-governance.sh datadir/governance.json \
  datadir/genesis.json datadir/governance-pins.json --account dev-admin --sender CURRENT_OWNER
# Add --broadcast only for an explicitly intended ownership handoff.
```

Deploying the controller, schedule and ownership transfer are separate
transactions. Partial broadcast or pins-output failure requires receipt/ownership
inspection before retrying. Do not blindly rerun a non-idempotent deployment.

**Operational ownership is not proxy upgrade ownership.** This helper does not
transfer the manager, registry, EEZL2, history or FeeVault ProxyAdmins, recovery
roles, or attester. Any retained upgrade admin may bypass the manager's operational
timelock by changing its implementation. The proxy integration test demonstrates
both this separation and a timelocked implementation call after a separate,
explicit manager-ProxyAdmin ownership handoff. It is not automatic policy.

## Reading and modelling the schedule

After deployment finalizes, administrative inspection is read-only:

```sh
cargo +1.96.0 run --locked -p hydration-governance --example runtime_schedule -- \
  datadir/governance-pins.json 0
```

The reader pins every code/state call to one finalized L1 block hash with
EIP-1898 requireCanonical. It checks its configured deployment, code, L2 genesis,
grid, release/artifact identities, bounded ordered history and retained safe
prefix. Missing finality or unsupported hash reads never fall back to latest.
Finalized cancellations are reflected by reading retained storage again. The
reader trusts the RPC; it is not a light client or a storage proof verifier.

Metadata lookups are allowed only through the conservative grid horizon
`finalized_timestamp + min(MIN_NOTICE, CANCEL_NOTICE)`. Later unseen enactments
or cancellations cannot change selection inside that horizon. A stale lookup
errors rather than guesses. `RuntimeContext` retains history through pause and
recovery, checks consumer identity and supported rehearsal IDs, and issues
recheckable permits. All of this is in memory and separate from production.

Release IDs 0/1 are **not** `config.hydration.rulesVersion` (currently 1), native
operations V0/V1, history encoding version 1, validation version 9 or signing
domain 7. The complete chain document must be committed by reviewed manifests:
the genesis header alone does not bind Hydration/RollupX extra configuration.
The library neither verifies installed binaries nor introduces a new vkey policy.

## Deliberately not activated

The source revm factory/guard and 0x0801 marker are not installed in this evm2
profile. Ordinary production still does not wait for L1; the prover stays offline.
Future dynamic activation needs an agreed evidence/identity/key/replay contract
and engine-native implementation across every consumer. The current
[coordinated-upgrade procedure](../runbooks/chiado-deployment.md#rollup-manager-and-coordinated-upgrades)
remains authoritative. This port does not establish an end-to-end runtime upgrade,
OpenGov authentication, native governance, or height-aware proof enforcement.
