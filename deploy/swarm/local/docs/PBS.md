# Private L1 builder path

The private L1 uses the pinned Ethereum-package PBS topology: a separate
Reth-rbuilder execution client and Lighthouse beacon, a Flashbots-style relay
(housekeeper and API), PostgreSQL, Redis, and MEV-Boost connected to the canonical proposer.
All interfaces remain on private overlays; no host ports are published.

PostgreSQL and Redis both belong to `eez-devnet-pbs`, with dedicated persistent
volumes and a private stack overlay. No shared database service or platform
database network is required. The relay uses the non-superuser login/database
`eez_devnet_relay`. Only PostgreSQL mounts its dedicated admin password; relay
tasks receive their own password/signing secrets. Do not inspect secret contents
or put DSNs in command args.

## Provision once

From this directory, after the L1 is finalized. On another developer's machine,
use Docker Swarm and label the intended data node `platform.data=true` as in the
[L1 prerequisites](../README.md#prepare-once). The label selects local storage;
it does not require a separately deployed platform stack. Generate each secret
once; ordinary restart reuses existing secrets and volumes:

```sh
openssl rand -hex 32 | sudo docker secret create eez-devnet-relay-password -
openssl rand -hex 32 | sudo docker secret create eez-devnet-postgres-password -
(printf '00'; openssl rand -hex 31) | sudo docker secret create eez-devnet-relay-signing-key -
sudo docker volume create eez-devnet-414141-redis
sudo docker volume create eez-devnet-414141-postgres
sudo docker volume create eez-devnet-414141-pbs
sudo docker volume create eez-devnet-414141-builder
sudo docker volume create eez-devnet-414141-builder-beacon
sudo docker stack deploy --detach=true -c relay.yml eez-devnet-pbs
sudo docker service ps eez-devnet-pbs_postgres --no-trunc
sudo docker service logs --tail 30 eez-devnet-pbs_postgres
sudo docker service logs --tail 30 eez-devnet-pbs_relay-housekeeper
sudo docker service logs --tail 30 eez-devnet-pbs_relay-api
```

PostgreSQL's official entrypoint runs `provision-relay.sh` only on an empty data
volume, creating the separate runtime role/database and revoking PUBLIC access.
Require PostgreSQL readiness and the housekeeper's metrics listener. Swarm does
not order service startup; relay tasks may restart while the database initializes.
Existing data volumes skip initialization, so changing a secret alone does not
rotate an existing database password. Partial initialization needs inspection
and explicit recovery, not volume deletion or automatic reprovisioning. The
API wrapper waits for that post-migration metrics endpoint. Read the API's
**public** BLS key from its `Using BLS key` log; supply it as
`EEZ_DEVNET_RELAY_PUBLIC_KEY` when rendering bootstrap state below. This pins the
relay identity for rbuilder and MEV-Boost; no signature-check bypass is enabled.

## Bootstrap and start

The canonical execution RPC exposes `admin_nodeInfo` privately to discover its
public peer identity. Bootstrap records its service VIP, the persistent beacon
peer ID, genesis time and relay URL in the PBS volume. Re-run bootstrap if those
bindings change, stopping the builder first. A fresh relay signing secret needs
new public bindings; never keep the old public key with a replacement secret.

```sh
sudo env EEZ_DEVNET_RELAY_PUBLIC_KEY=PUBLIC_BLS_KEY docker stack deploy --detach=true \
  -c pbs-bootstrap.yml eez-devnet-pbs-bootstrap
sudo docker service ps eez-devnet-pbs-bootstrap_bootstrap --no-trunc
sudo docker service logs eez-devnet-pbs-bootstrap_bootstrap
sudo docker build -f Dockerfile.builder -t eez-devnet-builder:261124-pbs-v1 .
sudo docker stack deploy --detach=true --resolve-image never -c builder.yml eez-devnet-builder
sudo docker stack deploy --detach=true -c boost.yml eez-devnet-boost
```

The builder image adds a static BusyBox startup shell to the unchanged pinned
rbuilder bytes. This versioned local image exists only on the single data node;
publish and pin its digest before deploying to another host. No Rust rebuild
occurs here. Builders have their own datadirs; never mount the canonical EL or
beacon datadir into the builder services.

The builder uses Ethereum-package's public fixture identity
`0xb9e79D19f651a941757b35830232E7EFC77E1c79`. Its public key material in
`builder.template.toml` is for disposable private development only. It needs
test ETH to fund the configured 1 ETH subsidy per bid. The initial server
deployment explicitly transferred 100 test ETH from the prefunded fixture.
Monitor its balance; topping up is a separate intentional test-funding action.
Lark staging must replace fixture credentials with separately provisioned keys.

Require the builder beacon to be nonoptimistic and both execution clients to
follow the same head. Bootstrap uses trusted EL peering and a retained beacon
boot peer so canonical service restarts can reconnect. After restart, verify
head agreement again. Missing bids retain the canonical proposer's normal
local-execution fallback; this is not evidence that PBS is working.

## Verify and operate

`check-pbs.sh` checks both chain IDs, nonoptimistic builder consensus, relay
housekeeper readiness and MEV-Boost health. It selects a delivered payload from
the expected fixture builder and verifies that its hash is canonical at that
execution height. Execute it as a read-only Swarm task on `eez-devnet_l1`, using
the genesis-generator image and a versioned Docker config as with `check.sh`.
Retain failed and successful task logs. This verifies block delivery, not EEZ
cross-chain semantics, ordered refunds or blob availability.

From the repository root, submit that bounded check with:

```sh
sudo bash scripts/local-devnet.sh check-pbs
```

`pbs-canary.sh` is a separate, explicitly broadcasting diagnostic: it sends a
0.01 test ETH payment from the public prefunded fixture through `eth_sendBundle`,
targeting two blocks ahead, and checks the canonical receipt. It waits for equal
execution heads and an open bundle endpoint before submitting. Run it only as an
intentional owned test; do not overlap fixture nonce use with other workloads.
After a deployment, also require the builder service's `UpdateStatus.State` to
be `completed` before submitting: an open RPC can still belong to the outgoing
task. Pending builder bundles are in memory and can be lost on restart.

The local sample bidder is configured to start at the 12-second slot boundary.
The pinned builder's sample bidding service drops notifications before its
start time and has no timer to reconsider an early candidate. The default
-8000ms could suppress the sole candidate on a quiet devnet; -12000ms allows
that candidate to bid immediately. This is private-network configuration,
not a change to ZisK, EEZ execution rules or the Core protocol.

Inspect service logs/tasks through Swarmpit or `sudo docker service logs/ps` for
`eez-devnet-builder_builder`, `eez-devnet-builder_builder-beacon`,
`eez-devnet-pbs_relay-api`, `eez-devnet-pbs_relay-housekeeper`,
`eez-devnet-pbs_redis`, `eez-devnet-pbs_postgres`, and `eez-devnet-boost_mev-boost`.

For daily whole-network operation use `local-devnet.sh down` / `up` and
`check-all` from the repository root. The [complete lifecycle](../README.md#daily-use-the-complete-installed-devnet)
includes all PBS services and was exercised with preserved state and fresh
settlement. Runtime tasks now rotate Docker logs at 20 MB × 3 files; builder
logging defaults to info. Keep the same service specifications and volumes.

Stopping just `local-devnet.sh stop` stops the canonical L1 writers. To stop
the rest of PBS while preserving state, stop L2 consumers and relay writers,
then scale the remaining PBS services to zero too.
Keep database, Redis, PBS bindings and signing secrets for restart. Do not rotate
keys, delete volumes or recreate databases as part of ordinary restart. PBS
recovery still requires the same L1 genesis, relay signing key, database and Redis
state. This remains a single-host development network.

## Database backup and recovery

PostgreSQL data is in external volume `eez-devnet-414141-postgres`; Redis AOF is
in `eez-devnet-414141-redis`. Neither volume is removed by stack removal. The
shared server's PostgreSQL backup job does not back up this dedicated database.

For a consistent logical backup, pause relay API and housekeeper writers and
run `pg_dump -Fc --no-owner --no-acl` in a one-shot PostgreSQL 17 Swarm task on
`eez-devnet-pbs_relay`, connecting to `eez-devnet-pbs_postgres` as
`eez_devnet_relay`. Read the mounted relay-password secret inside the task; write
the dump with umask 077 into a dedicated backup volume. Retain the paired Redis
state and signing secret securely. Never print dumps or credentials in logs.

Restore into an isolated instance first, using the same runtime role and
`pg_restore --no-owner --no-acl --exit-on-error --single-transaction`. Compare
schema and exact table counts before reconnecting writers. Do not restore over
a running relay database. A rollback after new writes requires reconciliation;
reconnecting a stale copy can lose relay records. The migration below exercised
database restore, not a complete L1/PBS disaster-recovery procedure.

## Move from the former shared database, 2026-11-26

The original server deployment used a dedicated database on the shared instance.
It was migrated with API/housekeeper writers paused. A custom-format backup was
restored into the new stack-owned PostgreSQL service; exact row counts matched
across all eight public tables, and the runtime role's non-superuser privileges
were verified before restarting writers. The source database remains untouched
for recovery and is no longer used by runtime services.

The migration dump/checksums and count evidence are retained privately in
`eez-devnet-414141-postgres-migration-261126`. It is not needed for a fresh devnet.
The historical shared provisioning task was scaled to zero and its credential
mounts removed after migration. New developers initialize directly through
`relay.yml`; the separate shared-database provisioning stack has been removed.

Post-migration validation passed: relay/canonical payload lookup remained
available, and a fresh Hydration canary incremented the counter from 1 to 2 in
L2 block 1363. Its settlement advanced the on-chain commitment to canonical
L2 block 1368 (`0x49f23751709ff15e287b77403b892e71595a4c9bc2fce3fb8567ee37adbc00f7`).
Service inspection confirmed PostgreSQL/Redis use only the private stack overlay
and relay tasks use only that overlay plus L1; none uses the shared DB network.

## Executed validation, 2026-11-26

L1 414141: a canary bundle produced relay-delivered canonical block 12529,
hash `0xf59ad10406fe56cab737d67b6155f10176a448db0d23376137dbb2a5a1cde7a9`.
Transaction `0x1019203da566c6caa5cde25274d5f5bf48fb8783cec82ea36deaf013f616a65e`
has status 1. The independent relay/canonical-hash check completed successfully.
After restarting the builder and waiting for its rollout to complete, another
canary settled in block 12579,
hash `0x28628fcbb2557342078f474db79ac97c8e93366d22723a556f89e63637f30bf8`,
tx `0xaf72c0f25c5843b6ebdda55eb13221bf1250011806d4c95dfa77e8ec8dad5257`.

Initial failures are retained in Swarm task history: relay key prefix mismatch,
builder peering during canonical restart, early candidate timing, a receipt
query without a timeout, a probe racing startup, and an in-memory bundle lost
by the outgoing task during rollout. These later passes do not erase those
failures or establish durable recovery. Local counter settlement with blob
publication is recorded in the [L2 runbook](L2.md) and the migration above.
Cross-chain calls, independent blob reconstruction, refunds and full L1/PBS
restart/restore remain unqualified.
