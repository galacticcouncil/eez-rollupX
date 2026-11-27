# rollupX

An EEZ rollup with bidirectional L1/L2 calls, derived from
[eez-rollup0](https://github.com/eez-association/eez-rollup0).
Core contracts are pinned in `eez-core-protocol`;
[Hydration customizations](docs/hydration.md) are tracked separately.

## Run the full local devnet (Docker Swarm)

For an **already provisioned** devnet, run from the repository root:

```sh
sudo bash scripts/local-devnet.sh up
sudo bash scripts/local-devnet.sh status-all
sudo bash scripts/local-devnet.sh check-all
```

This resumes L1 **414141**, PBS/builder, L2 **424242**, signer and installed
explorers: 21 services with both explorers installed.
`check-all` prints a job name; require `Complete` with exit 0:

```sh
sudo docker service ps JOB_NAME --no-trunc
sudo docker service logs --tail 100 JOB_NAME
```

Replace `JOB_NAME` with that printed name.
[Check explorer HTTP separately](deploy/swarm/local/docs/EXPLORERS.md#open-and-check).

Stop the complete devnet while retaining its data:

```sh
sudo bash scripts/local-devnet.sh down
```

To **erase and recreate** the complete devnet with fresh state:

```sh
sudo bash scripts/local-devnet.sh reset        # preview resources and images
sudo bash scripts/local-devnet.sh reset --yes  # delete state and provision again
```

Reset reuses installed images and recreates L1, PBS, L2 and both explorers.
See [reset requirements and recovery](deploy/swarm/local/README.md#reset-the-whole-devnet).

`up` reuses existing images, configuration, keys and volumes. It does not
provision a new network. See [first-time setup and operations](deploy/swarm/local/README.md)
for installation, explorer access, logs and recovery. Pending unsettled requests
are in memory and may need resubmission after restart.

## Other deployments

| Use | Guide |
| --- | --- |
| Disposable Kurtosis protocol network | [Kurtosis guide](testing/kurtosis/README.md) |
| Public Chiado L2 | [Chiado quick start](docs/runbooks/chiado-quickstart.md) |
| Join an existing Chiado rollup | [Existing-rollup procedure](docs/runbooks/chiado-existing-rollup.md) |
| Lark staging | [Lark bootstrap and operations](deploy/swarm/lark/README.md) |
| Deployment source layout | [Deployment index](deploy/README.md) |

## How it works

- The sequencer produces ordinary L2 blocks locally and Sync blocks carrying
  cross-chain work.
- Composer simulates cross-chain calls and submits their settlement through an
  L1 builder. Speculative L2 execution can be replaced during reconciliation.
- The proof signer independently re-executes batches and signs their recomputed
  public inputs. The current backend is ECDSA attestation, not a ZisK validity proof.
- A follower can reconstruct the L2 from canonical L1 commitments and blob data.

Follow a transaction through the [block lifecycle](docs/hydration/block-production-lifecycle.md).
This profile requires fresh matching contracts, genesis and datadirs. See the
[history/offline-proving contract](docs/proposals/l1-origin-and-offline-proving.md);
there is no migration of an existing network into this profile.

## Interfaces

All `eez_*` methods and wallet discovery use Composer fronts. Standard
`debug_*` calls use the regular node RPC. Swarm RPCs stay on private overlays;
[local endpoints](deploy/swarm/local/docs/L2.md#interfaces) and
[Chiado endpoints](docs/runbooks/chiado-deployment.md) describe their respective access.

Front witnesses require Composer's HTTP `debug` namespace; restrict both fronts
when enabling it. See the [client upgrade/rollback contract](docs/proposals/composer-wallet-discovery.md#compatibility-and-recovery).

| Contract | Reference |
| --- | --- |
| Cross-chain admission, scheduling, fees and recovery | [Settlement policy](docs/configurable-settlement-policy.md) |
| Composer/prover validation and settlement ownership | [Prover RPC specification](crates/eez-control-rpc/SPEC.md) |
| Gas estimation | [Estimation contract](docs/proposals/composer-gas-estimation.md) |
| Wallet/Composer discovery and client upgrades | [Discovery contract](docs/proposals/composer-wallet-discovery.md) |

### L1/L2 settlement correlation RPC

Both Composer fronts expose the exact canonical mapping derived from
accepted `postAndVerifyBatch` transactions. These examples assume a Composer
front exposed locally at port 18998:

```bash
# L2 number or 32-byte hash -> its L1 posting block/transaction and exact range.
curl -s http://localhost:18998 \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eez_getSettlementByL2Block","params":["0xcc"]}'

# L1 number or 32-byte hash -> zero or more settled L2 ranges.
curl -s http://localhost:18998 \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":2,"method":"eez_getSettledL2RangesByL1Block","params":["0x23"]}'
```

Selectors also accept `{"blockNumber":"0xcc"}` or
`{"blockHash":"0x…"}`. Numbers are Ethereum hex quantities. An unknown L2
block returns `null`; an L1 block with no accepted batches returns `[]`.
Responses include every exact L2 block hash, the posting transaction hash and
index, `canonicalL2`, and `l2Finalized`. A same-height replacement remains
discoverable by its old hash but is marked non-canonical.

Set `EEZ_L2_DATADIR` to retain the MDBX index under
`$EEZ_L2_DATADIR/eez-correlations`. On its first run after this feature is
enabled, the deriver performs one full L1 scan to backfill history. With no
configured datadir the methods still work for batches observed during that
process, but their history does not survive restart.

This mapping means “the L1 transaction that published and settled this L2
block.” It is distinct from an L1-origin field embedded in every L2 header,
which this protocol does not currently define.

## Exercise it

Use the [local Swarm validation guide](deploy/swarm/local/docs/VALIDATION.md) for
cross-chain/blob checks, or the [Kurtosis workloads](testing/kurtosis/README.md)
for disposable networks. [scripts/xchain-test.sh](scripts/xchain-test.sh) is the
existing mixed cross-chain driver.

For staged Chiado workloads, use
[scripts/run-chiado-staged-performance.sh](scripts/run-chiado-staged-performance.sh)
and the [performance procedure](docs/runbooks/chiado-deployment.md#optional-workloads).
Its default `--no-verify` workload measures throughput/receipts; use `--verify`
for semantic assertions.

## Development

Use Rust **1.96.0**, Foundry **1.7.1** and locked Cargo dependencies. Source builds
need LLVM 23, Polly, Clang 23 and `m4`; follow
[build and validation instructions](AGENTS.md#build-and-validate).
See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) and [LICENSE](LICENSE).
