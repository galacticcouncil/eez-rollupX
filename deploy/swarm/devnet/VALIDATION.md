# Local cross-chain qualification

Run against the existing [L1/PBS](PBS.md) and [L2](L2.md). This finite Swarm
job spends public fixture gas and deploys disposable test contracts. It does not
deploy another rollup or regenerate genesis. Require IDs 414141 and 424242;
the wrapper refuses other chains before funding or submitting scenarios.

The pinned Core scenarios are `counter` (L1→L2), `counterL2` (L2→L1), and
`nestedCounter` (L1→L2→L1). The existing protocol runner checks state and exact
execution tables. Its independent collectors re-read canonical receipts,
validate causal relationships, retrieve Beacon blobs, recompute KZG versioned
hashes, decode native semantics and match signed trigger bytes. Require all three
scenarios to pass both runner and evidence checks. This is a selected smoke
test, not the full protocol suite, independent follower replay, backup/restore,
fee-refund qualification or production ZisK proving.

## Build once per validation revision

Run from the repository root with the exact protocol gitlink initialized. Match
the deployment image to the running network's source revision. The image adds
validation tools to that image's existing Foundry/compiler and contract snapshot;
do not use it across a protocol or integration-contract change without rebuilding
the deployment base. Read-only Git metadata at run time must match these sources.

```sh
revision=$(git rev-parse HEAD)
protocol=$(git ls-tree HEAD eez-core-protocol | awk '{print $3}')
tag=${revision:0:8}
sudo docker buildx build --builder default --platform linux/amd64 \
  --resource cpu-period=100000 --resource cpu-quota=400000 \
  --resource memory=24g --resource memory-swap=24g \
  --build-arg DEPLOY_IMAGE=eez-devnet-deploy:5f8813d4 \
  --label org.opencontainers.image.revision="$revision" \
  --label io.eez.protocol.revision="$protocol" \
  --load -f deploy/swarm/devnet/Dockerfile.validation \
  -t "eez-devnet-validation:$tag" .
```

Build with Rust 1.96.0 and locked dependencies. Compilation is capped at four
jobs; the target directory is removed within its build step rather than retained
as another compiler cache. The resulting local image is development tooling,
not a published or CI-qualified release. Record uncommitted inputs separately.

## Submit one finite exercise

The protocol runner requires fee quotes in both directions. The base bring-up
profile disables collection and has no quote model. Apply the existing private
Kurtosis fee assumptions with the same runtime images before this exercise:

```sh
sudo env EEZ_DEVNET_NODE_IMAGE=eez-devnet-node:5f8813d4 \
  EEZ_DEVNET_SIGNER_IMAGE=eez-devnet-signer:5f8813d4 \
  docker stack deploy --detach=true --resolve-image never \
  -c deploy/swarm/devnet/l2.yml -c deploy/swarm/devnet/l2-fees.yml eez-devnet-l2
```

Require the Composer update to complete and its canonical catch-up to finish.
This restarts the Composer with synthetic ETH parity, explicit zero fixed costs,
20% quote profit allowance, L2 fee recipient `0x4444…4444` and L1 refund recipient
`0x5555…5555` at 90%. These are the repository's private-test assumptions, not
Lark pricing. No genesis, contract, protocol or runtime binary changes are needed.
The base `l2.yml` keeps its original disabled defaults. Daily `up` resumes the
installed profile; `l2-start` reapplies the base and disables collection again.
To roll back deliberately, deploy `l2.yml` alone with the same images. Historical
blocks remain replayable and prior fees remain paid. Reconcile unsettled requests
around either restart; pending queue ownership is not durable.

Create the two dedicated Solidity cache volumes once. They hold compiled public
fixtures and the compiler index, never worker wallets. The runner still checks
the full protocol gitlink and Foundry validates its source/compiler cache. Choose
new cache volume names when porting this definition to a different protocol pin.
The first run compiles the full pinned scenario inventory; later runs reuse it.

```sh
sudo docker volume create eez-devnet-protocol-84a5b520-out
sudo docker volume create eez-devnet-protocol-84a5b520-cache
```

Use a new timestamp and evidence volume for every run, including a diagnostic
retry. The job refuses a previously started evidence directory. No retry policy
repeats broadcasts automatically. Do not run another workload using the same
funding accounts concurrently.

```sh
stamp=$(date -u +%y%m%d%H%M)
evidence="eez-devnet-validation-$stamp"
sudo docker volume create "$evidence"
sudo env "EEZ_DEVNET_VALIDATION_IMAGE=eez-devnet-validation:$tag" \
  "EEZ_DEVNET_VALIDATION_VOLUME=$evidence" "EEZ_DEVNET_CHECKOUT=$PWD" \
  docker stack deploy --detach=true --resolve-image never \
  -c deploy/swarm/devnet/cross-chain.yml "eez-devnet-validation-$stamp"
sudo docker service ps "eez-devnet-validation-${stamp}_check" --no-trunc
sudo docker service logs -f "eez-devnet-validation-${stamp}_check"
```

Require task `Complete`, exit 0 and passing `protocol-e2e/summary.json` inside
the evidence volume. Submission success or transaction inclusion alone is not
qualification. The volume retains normalized scenario logs, JSON evidence,
raw Beacon responses, helper hashes, funding receipt and the exit code.
Private worker wallet CSV files and keys remain in the disposable task filesystem;
do not copy that filesystem wholesale into reports or source control.

The one-shot job appears in Swarmpit. It has capped Docker logs, two CPUs and
4 GiB memory; no published ports, node datadir access or Docker socket. Its
deployment and Git metadata mounts are read-only. It is excluded from the
daily devnet `up` / `down` lifecycle. Inspect and retain a failed run before
creating a new one; never interpret a retry-only pass as an initially clean run.

The first run on 2026-11-26 (`2611261631`) failed all three cases before trigger
submission because quotes were disabled. Its evidence remains retained. That run
completed the initial Solidity compilation; only its 68 MiB output and 556 KiB
compiler index were copied into the dedicated cache volumes, excluding wallets.

## Live result — 2026-11-26

Runtime source was `5f8813d4`, configuration baseline `20882174` plus these
validation changes, and Core pin `84a5b5207880f192a6a5896cbfe0bac5249db47f`.
Run `2611261644` used the fee overlay and passed all three upstream scenarios in
135 seconds, reusing the compiled fixtures. Its independent collection failed
because Debian's older `mawk` did not match the collector's `{64}` hash regex.
The same expression matched on the host. GNU awk is now an explicit dependency
of `Dockerfile.validation`.

Read-only evidence job `eez-devnet-evidence-2611261701` then rechecked the **same
transactions** with the corrected image `eez-devnet-validation:20882174-gawk`
(image ID `sha256:8a69cb484b801f01f806ead5f084fcc2f06e4c083b62e656c4e0e02cfe9cc37e`).
It completed with exit 0 in 7.5 seconds: 3/3 receipts, causal graphs and native
semantic-blob checks passed. KZG authentication, signed-trigger binding and exact
execution-table checks remained enabled. The two Rust checker hashes were
identical before and after the awk dependency correction; no calls were resent.
Both original failed results remain retained, so this is success after explicit
configuration/tooling corrections, not an initially clean full-run result.

| Scenario | Source transaction | L1 settlement block | L2 delivery/load block |
| --- | --- | --- | --- |
| L1→L2 `counter` | `0xc5c66ed60f8865bd0f2eb5f8a188683f0372205d2449e556210ebcf2f7be2194` | 14346 | 8652 |
| L2→L1 `counterL2` | `0x92573a42c68fd978de37e49e26cd1468a8b16f99cdbdb6d446449e1d4e17ec8d` | 14349 | 8670 |
| L1→L2→L1 `nestedCounter` | `0x632285c5bba82f0b8b489e49096c958423137d1b260ed084207b2bbd4e2a418f` | 14352 | 8688 |

The L1/L2 explorer APIs also returned successful indexed records for the source
transactions and the inbound native type `0x45` delivery. The nested trigger is
indexed successfully on L1. No automated browser check was performed.

Evidence is retained in the correspondingly named external volumes and ignored
`artifacts/devnet-validation/{2611261631,2611261644,2611261701}/` directories.
The last directory contains the three passing independent JSON bundles and raw
Beacon responses; the second contains the original successful execution logs.
The read-only recheck script is retained with its evidence, alongside exact
checker hashes. These artifacts contain public test transactions, not wallet CSVs.

Focused Swarm tests: 37 passed. The tooling suite passed 616 tests with nine
explicit exclusions (opt-in Docker payload/runtime, native archive relocation,
real Kurtosis resource probes and unavailable Gitleaks). Its initial sandboxed
attempt failed because local test-server sockets were denied; the rerun outside
the sandbox passed. Chiado/Ethereum configuration and settlement-policy checks,
shell syntax and whitespace checks passed. No Rust or contract behavior changed;
the full Rust/Kurtosis/protocol matrices were not run.

The devnet remains running with the fee overlay. Dedicated builder-refund
accounting/negative controls, independent follower replay, the other 61 protocol
scenarios and backup/restore remain unqualified. Explorer-inclusive stop/start
was exercised subsequently, as recorded below.

## Controlled restart — 2026-11-27

Configuration revision `6cca9954`, runtime `5f8813d4` and the unchanged Core pin
were used for a complete `local-devnet.sh down` / `up`. All 21 runtime services
reached zero running tasks, then resumed using their saved specifications.
Fingerprints of every service specification, excluding only replica count,
matched before and after: images, volumes, configuration/secret references and
the active fee overlay were preserved. No images were built and no deployment,
genesis, bootstrap or funding job was rerun by the lifecycle helper.

Read-only before/after snapshots retained identical deployment checksums,
counter value 3, canonical L1 block 14352 and L2 block 8688 hashes/state roots,
the nested source/settlement/delivery receipts, settlement correlation and both
explorers' indexed transaction records. L1 advanced 19821→19829 and L2 advanced
41506→41596; their explorer heads also advanced. Both private HTTPS homepages
returned 200. `eez-devnet-check-261127110314` completed with exit 0, checking
L1/consensus, canonical PBS delivery, L2 advancement and retained safe state.

Fresh canary `eez-devnet-restart-canary-2611271059` completed with exit 0:
counter 3→4 in L2 block 41621, transaction
`0x8ff76b34872602c097f7e343b9b10cd8dfad9428ea7b865f136a335a08e0356f`.
Canonical settlement advanced through L2 block 41628, commitment
`0x85911d9d01a9f2980ff3746348d09621b4bd2dc80a9aec13191436992a61a06a`,
via L1 transaction
`0xdcf8944ad20b254b6f352f01997376f479bbb20005027b08a74384fa220a46f7`.
The L2 explorer indexed the fresh receipt and the correlation RPC marked it
canonical. This demonstrates new execution/settlement after the restart.

Fresh cross-chain job `eez-devnet-restart-cross-chain-2611271059` also completed
with exit 0. Its one selected `nestedCounter` scenario passed the complete runner
and independent receipt/causal/KZG/native-semantic checks (76.04 seconds for
execution and 2.517 seconds for independent collection). It reused the existing
image and compiler cache. Source transaction
`0xe5f0de7f6e80c1566645a5bb7fd97a2b71797d9e410a586471be2af462d847b0`
was settled by
`0x06a07025136d3bbf10117a32bffb5365828d4d35217dc53037d3f0d0751df689`,
with L2 delivery
`0x3a0512b3b1dc5184170de8ff0e0a1a2748989994f3e0648704f965d8fdc36022`.
This checks new cross-chain admission after recovery; the full 64-case inventory
was not repeated.

Evidence is retained in `eez-devnet-restart-2611271059` and ignored
`artifacts/devnet-restart/2611271059/`, including before/after snapshots,
`comparison.json`, specification fingerprints and lifecycle logs. The nested-job summary
and raw evidence are in the separate `eez-devnet-restart-cross-chain-2611271059`
volume and the artifact directory's `cross-chain/protocol-e2e/` subdirectory.
Documentation whitespace, edited links and shell-example syntax were checked;
no runtime implementation changed or source builds were needed. This is a
controlled graceful restart with retained local storage. It does not establish
crash durability, durable recovery of accepted queues, host-loss recovery or a
backup/restore. New settlement was checked for canonical inclusion, without
waiting for that posting block to finalize.
