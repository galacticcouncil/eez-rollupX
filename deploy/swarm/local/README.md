# Full local Swarm devnet

Private PoS L1 **414141** and Hydration L2 **424242**: execution/beacon/validator,
PBS with its own PostgreSQL/Redis, builder/MEV-Boost, Composer/signer and optional
L1/L2 explorers. With both explorers installed, there are **21 runtime services**.
This isolated network uses public test keys and ECDSA attestation.

## Run, check and stop

From the repository root, for an already provisioned devnet:

```sh
sudo bash scripts/local-devnet.sh up
sudo bash scripts/local-devnet.sh status-all
sudo bash scripts/local-devnet.sh check-all
```

`up` resumes saved service definitions, including installed explorers and the
active fee profile. It does not build images or rerun genesis, deployment or funding.

`check-all` prints a finite job name. Replace `JOB_NAME` below and require
`Complete` with exit 0:

```sh
sudo docker service ps JOB_NAME --no-trunc
sudo docker service logs --tail 100 JOB_NAME
```

The check covers L1/consensus, PBS, L2 advancement, deployment checksums, the counter
and safe head. Check [explorer HTTP access](docs/EXPLORERS.md) separately.

Stop all installed runtime services, retaining state:

```sh
sudo bash scripts/local-devnet.sh down
```

For a restart, run `down`, then `up` and `check-all`. Lifecycle commands wait for
tasks in dependency order; `EEZ_DEVNET_WAIT_SECONDS` sets the per-group timeout
(default 180, range 1–9999). Run one lifecycle operation at a time. After a timeout,
inspect the reported service before retrying. Unsettled queues are in memory;
clients may need to resubmit after restart.

## Reset the whole devnet

Preview the reset without changing anything:

```sh
sudo bash scripts/local-devnet.sh reset
```

Erase the current network and provision it again:

```sh
sudo bash scripts/local-devnet.sh reset --yes
```

This deletes the current L1/L2 chains, validator state, relay PostgreSQL/Redis,
explorer databases/caches and devnet secrets. It creates fresh genesis, credentials
and contracts, funds the builder with 100 fixture ETH, enables synthetic fee quotes
and starts both explorers. Old transactions and pending requests are discarded.

Requires Python 3/PyYAML and the single-node data Swarm. Required images must
already exist locally; reset infers the five node/signer/deploy/backend/frontend
image selections from installed services. The corresponding `EEZ_DEVNET_*_IMAGE`
variables override them. Private-host explorer access is retained when installed;
`EEZ_DEVNET_EXPLORER_ACCESS` can select `overlay` or `private-host` explicitly.

For a fresh installation or recovery after partial setup, select all five images:

```sh
sudo env EEZ_DEVNET_NODE_IMAGE=YOUR_NODE_IMAGE \
  EEZ_DEVNET_SIGNER_IMAGE=YOUR_SIGNER_IMAGE EEZ_DEVNET_DEPLOY_IMAGE=YOUR_DEPLOY_IMAGE \
  EEZ_DEVNET_BLOCKSCOUT_IMAGE=YOUR_BACKEND_IMAGE \
  EEZ_DEVNET_EXPLORER_FRONTEND_IMAGE=YOUR_FRONTEND_IMAGE \
  bash scripts/local-devnet.sh reset --yes
```

Reset waits for successful setup/readiness jobs, including first L1 finality;
allow roughly 15–25 minutes. `EEZ_DEVNET_SETUP_WAIT_SECONDS` sets each phase's
timeout (default 1800, range 1–9999). It stops on failure without automatically
retrying funding or contract broadcasts. Inspect the reported task/logs before
recovery. For another complete reset after partial setup, supply all five image
variables explicitly if their services are missing.

Only the named current-devnet resources are removed. Unrelated services, images,
saved evidence, protocol compiler caches and old-network archives remain.
There is no rollback of erased state; recovery creates another fresh network.
Use `down` / `up` when you want to keep the chain.

## First installation

`up` requires the base services to exist. For unattended installation, supply all
five image variables and use `reset --yes` above; the staged procedure is:

| Order | Step |
| --- | --- |
| 1 | Prepare/start L1 below; require its readiness job to pass. |
| 2 | [Provision relay, builder and MEV-Boost](docs/PBS.md); require PBS checks to pass. |
| 3 | [Select images, deploy contracts and start L2](docs/L2.md). |
| 4 | [Add both explorers and private access](docs/EXPLORERS.md). |
| 5 | Use the full lifecycle commands above. |

L1 requires Docker Swarm, a data node labelled `platform.data=true`, Bash and
OpenSSL. Prepare once:

```sh
sudo bash scripts/local-devnet.sh prepare
sudo docker service ps eez-devnet-414141-prep_prepare --no-trunc
sudo docker service logs --tail 50 eez-devnet-414141-prep_prepare
```

Require `Complete` and `Prepared private L1 genesis and 64 fixture validators`.
Then start and check L1:

```sh
sudo bash scripts/local-devnet.sh start
sudo bash scripts/local-devnet.sh check
```

Inspect the printed check job as above and require successful completion.
These `start` / `stop` commands control **L1 only**. Likewise `l2-start` /
`l2-stop` control L2 only. Use `up` / `down` for the complete installed network.

## Logs, storage and recovery

Inspect services in Swarmpit or, for example:

```sh
sudo docker service ps eez-devnet-l2_eez-node --no-trunc
sudo docker service logs --tail 100 eez-devnet-l2_eez-node
```

- Runtime data lives in external volumes pinned to the data node. Preserve
  genesis, validator slashing history, Engine JWT, deployment bindings and datadirs together.
- Updates stop single writers first. Never run a second validator using the same keys.
- Docker logs rotate at 20 MB × 3 files per task; old tasks and build caches need
  separate inspection. Use `du` for physical allocation and remove only identified,
  unused owned caches. Do not prune chain/witness data to manage routine disk usage.
- There is no automatic reset or deployment retry after a partial broadcast.
  Inspect receipts/state before recovery. Back up paired state and restore in
  isolation; the full restore procedure is not yet qualified.

The local L1 uses 12-second slots, 64 validators and Fulu/BPO1 from genesis.
[Validation](docs/VALIDATION.md) explains cross-chain/blob checks and their scope.
[Source layout and compatibility](../README.md) covers stack/config changes;
[Hydration rules](../../../docs/hydration/local-devnet.md) owns the genesis profile.
