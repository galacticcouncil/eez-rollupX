# Hydration governance port

| Field | Value |
| --- | --- |
| Design status | User-authorized port of the governance PoC; dynamic production runtime activation remains a draft, not an accepted profile change |
| Date | 2026-11-24 |
| Source baseline | Galactic Council eez-rollup0 `runtime_upgrades` at `2858f7e7d864bed222c6c779dff129206297e9f0`, including local guarded-adapter/snapshot changes; governance source commits `5190f47`, `fa74cd9`, `2858f7e` |
| Target baseline | Galactic Council eez-rollupX, local `../eez`, branch `gov`, `9666c539919cdcebb7d939e30ede133312ba3434` |
| Protocol baseline | `84a5b5207880f192a6a5896cbfe0bac5249db47f`; unchanged |

## Scope and compatibility

Port timelocked Root authorization, authority rotation, release/height metadata,
the finalized administrative reader, and the engine-neutral rehearsal model.
Adapt manager integration to pinned Core `Rollup` proxies, its four-argument
initializer and `EEZContract()` getter; registration is performed as manager owner.
Keep the core ABI, protocol pin, registered-key derivation, validation identity,
native formats, genesis and production execution paths unchanged.

The current engine is evm2/Reth 2.11, not the source's revm/Reth 2.2. Ordinary
production must not wait for L1 and the signer must remain offline. The old
`GuardedEvm`/`ChainEvmConfig` wrapper is therefore intentionally not installed or
copied as a replacement engine. Its snapshot publication, pause/recovery and
selection checks are preserved in isolated `hydration-governance`; the optional
permit API is not an evm2 hook. No shipping binary depends on this crate.

Rehearsal release IDs 0/1 do not renumber `config.hydration.rulesVersion = 1`,
native operations V0/V1, history format version 1, RPC validation version 9 or
signing domain 7. A schedule entry is not authorization to switch those profiles.
The full chain document, including extra genesis configuration, must be bound by
reviewed release manifests; genesis header identity alone is insufficient.

## Source inventory

| Source component | Disposition in this port |
| --- | --- |
| AuthorityRegistry / UpgradeController | Carried as independent contracts, preserving epoch, nonce and timelock behavior |
| ExecutionUpgradeSchedule | Carried as an opt-in authorization metadata registry; not proof enforcement |
| Deploy scripts and local rehearsals | Adapted to actual registry/manager proxies and current ownership checks |
| Finalized reader and local snapshot consistency changes | Carried into an isolated role-free governance library, not the offline signer |
| Runtime selection / retained pause state | Adapted to engine-neutral block coordinates and explicit recheckable permits |
| Old guarded revm EVM/config and node executor builder | Intentionally different: do not restore superseded engine/profile or block production on live L1 reads |
| Runtime marker at 0x0801 | Not installed in production; an evm2 activation/rehearsal needs an explicit profile design |
| Deployment helper and identity inspector | Opt-in only; default deploy/startup is unchanged |
| Native/OpenGov authentication and height-aware proof selection | Still absent, as in the source checkpoint |

## Permission boundaries

Manager operational ownership and ProxyAdmin ownership are separate. Handing
the manager to UpgradeController does not timelock implementation upgrades.
Registry, manager, L2 EEZ/history/FeeVault ProxyAdmins, recovery and the proof
attester remain separate authorities unless deliberately transferred under a
reviewed permission plan. No automatic admin transfer is added here.

The registered vkey binds the current network profile, not a padded ECDSA address.
Rehearsal hashes are fixtures and cannot replace a deployed profile/key. Existing
incompatible upgrades still require the [coordinated key/runtime procedure](../runbooks/chiado-deployment.md#rollup-manager-and-coordinated-upgrades).

## Acceptance and validation

- Run authority, replay/epoch, schedule/cancellation and ownership tests against
  the exact pinned proxy contracts, plus a timelocked ProxyAdmin-call test.
- Test finalized-only reads, deployment/chain mismatches, cancellation, stale
  snapshots, changed safe history and unsupported rehearsal versions.
- Check that no production node, engine, signer, schema, genesis or pin changes.
- Use the target Rust/Foundry versions and existing dependency pins; report any
  tooling/version limitations separately from test results.
- No deployment, funding, service change, issue/PR creation or push is authorized
  by this port. Live/proof validation remains separate from local tests.

## Follow-up design, not implemented activation

An operational upgrade path needs authenticated schedule evidence compatible
with offline proving, the complete chain-document/validation identity and
registered-key policy, historical replay, all evm2 execution boundaries and
rollback rules. Those choices must be agreed before wiring this metadata into
ordinary block production. The old live-reader gate must not become an implicit
override of the accepted offline profile.

## Executed validation — 2026-11-24

- Rust 1.96.0: 21 governance tests, including finalized reader/selection/permit
  cases, and 38 existing Hydration config/rules/precompile/node tests passed.
  Both governance examples compile; the identity inspector was executed against
  `genesis.dev.json` through the production checked loader/profile constructor.
- Checksum-verified Foundry 1.7.1: all 227 integration Solidity tests passed,
  including 48 governance/ownership/proxy tests. Both local simulation scripts
  passed, with no RPC or broadcast.
- Seven new mocked deployment-wrapper tests and all 16 existing deployment
  preflight tests passed. These do not establish a successful real broadcast.
- Workspace Rust formatting, full integration Solidity formatting, targeted
  governance all-targets strict clippy, shell syntax and diff checks passed.
- Cargo.lock adds only the new local package and references existing dependency
  versions. No core, engine, signer, profile/genesis or production role dependency
  was changed. Full workspace clippy, dependency audit/deny, CI artifact builds,
  network/process E2E and production proof validation were not run for this port.

An initial rehearsal failed on Foundry's ephemeral `address(this)` owner check;
the proxy fixtures now use fixed explicit owner accounts. A node-wide helper
build also lacked a cached dependency in offline mode; the helper was moved to
the isolated governance package and uses the same checked production loader.
Final examples and rehearsals pass; no dependency-version relaxation or global
tool replacement was used. The port is not a deployment or production-readiness
claim.
