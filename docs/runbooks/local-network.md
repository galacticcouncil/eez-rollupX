# Local Hydration network

Run a complete rollup on one machine (macOS with Docker Desktop, or Linux) to
try changes by hand: Hydration rules from genesis, three independent proof
signers and an on-chain threshold of two. One script starts it and one test
script exercises it from outside, through the public RPC ports only.

This network is for development. It is not a deployment path: for a private
proof-of-stake L1 with a real builder and relay use the Kurtosis guide
([testing/kurtosis/README.md](../../testing/kurtosis/README.md)), and for
Chiado use the [Chiado deployment](chiado-deployment.md) runbook.

## Topology

[docker-compose.local.yml](../../docker-compose.local.yml), project `eez-local`:

| Service | Role |
| --- | --- |
| `composer` | `eez-composer` with its built-in development L1 (`EEZ_L1_CHAIN=testing`, chain 1337, 5 s blocks) and the L2 (chain 1338, 1 s blocks) |
| `signer-1`..`signer-3` | `eez-proof-signer`, one key each; any two settle a batch |
| `builder-stub` | [scripts/builder-stub.py](../../scripts/builder-stub.py): accepts the Composer's `eth_sendBundle` and keeps a copy of each blob transaction |
| `beacon` | [scripts/local-network/beacon-stub.mjs](../../scripts/local-network/beacon-stub.mjs) (Node, no dependencies): serves those blobs for the canonical L1 block of each slot |
| `pod` | holds the shared network namespace and the host ports |
| `init`, `contracts`, `test` | one-shot jobs in the deploy image ([testing/kurtosis/Dockerfile.deploy](../../testing/kurtosis/Dockerfile.deploy)) |

The built-in L1 RPC listens only on the Composer's loopback, so the stubs and
jobs share one network namespace with it. Mock bundles are not atomic and can
be reordered by tip; test real bundle inclusion and L1 fee refunds in Kurtosis.

The L2 genesis is the e2e fixture
([crates/eez-node-e2e/tests/fixtures/genesis.json](../../crates/eez-node-e2e/tests/fixtures/genesis.json))
with `config.hydration` (oracle updater and PEPL keeper are Anvil accounts 7
and 8) and the counter account at `0x…0800`. All keys are the public Anvil
development keys listed under `x-keys` in the Compose file. Never reuse them
on a public network.

## Prerequisites

- Docker with Compose v2. Give Docker at least 12 GB of memory and about
  40 GB of free disk for the first build.
- The pinned protocol checkout, from the repository root:

```bash
git submodule update --init --recursive eez-core-protocol
```

The host needs no Rust, Foundry or LLVM: the images build everything.

## Start

```bash
bash scripts/local-network.sh up
```

The first run builds three images (`eez-node:local`, `eez-proof-signer:local`,
`eez-deploy:local`; tens of minutes on a laptop), then:

1. `init` renders both genesis files, computes the contract addresses the
   deployer will create, and derives each signer's verification key
   ([init.sh](../../scripts/local-network/init.sh),
   [render-genesis.py](../../scripts/local-network/render-genesis.py)).
2. The signers, stubs and Composer start; Signer 1 alone is configured.
3. `contracts` compiles the contracts, deploys the registry, rollup manager and
   verifiers at those addresses, registers signers 2 and 3, and sets the
   threshold to two ([setup-contracts.sh](../../scripts/local-network/setup-contracts.sh)).
4. The Composer restarts with `EEZ_PROVERS` listing all three signers
   ([attestation quorum](attestation-quorum.md)).

It ends by printing the endpoints:

| Endpoint | URL |
| --- | --- |
| L2 RPC | `http://127.0.0.1:18688` |
| L1 RPC (through the bundle stub) | `http://127.0.0.1:18545` |
| L2 front: L2 transactions that call L1 | `http://127.0.0.1:18998` |
| L1 front: L1 transactions that call L2 | `http://127.0.0.1:18999` |

Ports bind to `127.0.0.1` and are fixed; stop another stack that uses them
first. Plain L2 activity settles at least once a minute; cross-chain calls
settle in their own L1 block.

## Test from outside

```bash
bash scripts/local-network.sh test
```

[test-counter-relay.sh](../../scripts/local-network/test-counter-relay.sh)
deploys `Value` on L1, its L2 proxy and `CounterRelay` on L2, then sends one
`bumpAndRelay()` through the L2 front. It passes when:

- the counter precompile advanced by one and L1 `Value` holds the new count;
- L1's answer was decoded back on L2 (`lastChanged`);
- the L1 rollup root equals the L2 safe block containing the transaction, and
  that block holds the new counter value;
- every successful `postAndVerifyBatch` since the transaction carried at least
  two proofs from two distinct registered signers (L1 verifies each proof and
  the manager's threshold is two).

It runs in the deploy image, so the host needs no Foundry. It deploys new
contracts each time and can be repeated on the same network.

## Daily use

```bash
bash scripts/local-network.sh status
```

```bash
bash scripts/local-network.sh logs signer-2
```

```bash
bash scripts/local-network.sh down
```

`down` keeps the chain data; the next `up` resumes it without rerunning
genesis or deployment. Queued cross-chain work is held in memory, so resend
unsettled transactions after a restart.

Resume only after short stops. L2 has one block per second of wall-clock
time, so after a stop the Composer first produces an empty block for every
missed second. After a 10-hour stop it replayed about 33,000 blocks, and
the next cross-chain call had to settle all of them: the signers missed the
proof deadline on every attempt and `test` timed out. After a long stop, use
`reset` instead.

```bash
bash scripts/local-network.sh reset
```

`reset` deletes all volumes, including both chains and the compiled contracts;
the next `up` creates a new network. Rebuild after changing Rust or contract
sources: `up` rebuilds the images, but a running network keeps its genesis
and contracts until `reset`.

## Common failures

- `L1 block zero differs from the rendered genesis` or `deployer already has
  transactions`: the volumes hold a different or partial network. Run `reset`.
- The L2 RPC does not start: read `logs composer`. A signer configuration
  mismatch is logged at Composer startup and that signer is left out.
- `test` times out waiting for settlement: check `logs` for
  `eez.composer.prover.range_retained` and the signers' logs. Two signers must
  answer within the proof deadline. If the network was resumed after a long
  stop, run `reset` (see Daily use).

## Verification status

On 2026-11-26, from fork `8fc7a73a` plus this change, on macOS arm64 (Docker
Desktop, 10 CPUs, 16 GB): after `reset`, a fresh `up` created the network and
`test` passed five times in a row (counter 0 → 5). Each settling post carried
two verified proofs; all three signer pairs (1+3, 1+2, 2+3) appeared. An
earlier run also passed after a short `down` and `up` on the same chain data.
On 2026-11-27, with the Node beacon stub, a resume after a 10-hour stop failed
as described under Daily use. After `reset`, a fresh network passed `test`;
the beacon served the post's blob for its slot and nothing for an empty slot. Linux
hosts, a stopped signer and long-running use are not yet exercised. CI does
not start this network, and it does not run the beacon stub's unit tests
([beacon-stub.test.mjs](../../scripts/local-network/beacon-stub.test.mjs)); run
them with Node 22 or newer:

```bash
node --test scripts/local-network/beacon-stub.test.mjs
```
