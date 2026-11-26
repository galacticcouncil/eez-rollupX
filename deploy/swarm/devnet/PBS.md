# Private L1 builder path

The private L1 uses the pinned Ethereum-package PBS topology: a separate
Reth-rbuilder execution client and Lighthouse beacon, a Flashbots-style relay
(housekeeper and API), Redis, and MEV-Boost connected to the canonical proposer.
All interfaces remain on private overlays; no host ports are published.

The relay uses the shared PostgreSQL service with its own non-superuser login
and database `eez_devnet_relay`. Runtime services mount only their own password
and signing secrets. The admin password is mounted only by the one-shot
provisioning task. Do not inspect secret contents or put DSNs in command args.

## Provision once

From this directory, after the L1 is finalized:

```sh
openssl rand -hex 32 | sudo docker secret create eez-devnet-relay-password -
(printf '00'; openssl rand -hex 31) | sudo docker secret create eez-devnet-relay-signing-key -
sudo docker volume create eez-devnet-414141-redis
sudo docker volume create eez-devnet-414141-pbs
sudo docker volume create eez-devnet-414141-builder
sudo docker volume create eez-devnet-414141-builder-beacon
sudo docker stack deploy --detach=true -c relay-provision.yml eez-devnet-relay-provision
sudo docker service ps eez-devnet-relay-provision_provision --no-trunc
sudo docker service logs eez-devnet-relay-provision_provision
```

Require completion of CREATE ROLE, CREATE DATABASE and REVOKE. Provisioning
deliberately fails on an existing role/database; it never resets another task's
state or silently changes an existing password. Partial failure requires
inspection and explicit recovery. This database participates in shared server
backups; any restore must be isolated.

```sh
sudo docker stack deploy --detach=true -c relay.yml eez-devnet-pbs
sudo docker service logs --tail 30 eez-devnet-pbs_relay-housekeeper
sudo docker service logs --tail 30 eez-devnet-pbs_relay-api
```

Require the housekeeper's metrics listener and successful database setup. The
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
`eez-devnet-pbs_redis`, and `eez-devnet-boost_mev-boost`.

Stopping just `local-devnet.sh stop` stops the canonical L1 writers. To stop
the rest of PBS while preserving state, scale these six services to zero too.
Keep database, Redis, PBS bindings and signing secrets for restart. Do not rotate
keys, delete volumes or recreate databases as part of ordinary restart. Builder
and relay data have no tested restore procedure yet. This remains a single-host
development network.

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
failures or establish durable recovery. Blob canaries, refunds, full restart/
restore and EEZ semantic settlement are still unverified.
