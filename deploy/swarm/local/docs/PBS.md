# Local relay, builder and MEV-Boost

Requires a healthy, finalized [local L1](../README.md#first-installation).
All commands run from the repository root.

`eez-devnet-pbs` owns PostgreSQL, Redis, relay housekeeper and API on private
overlays. Builder execution/beacon and MEV-Boost have separate services/datadirs.
The relay login/database is `eez_devnet_relay`; shared server PostgreSQL is unused.

## Provision once

```sh
openssl rand -hex 32 | sudo docker secret create eez-devnet-relay-password -
openssl rand -hex 32 | sudo docker secret create eez-devnet-postgres-password -
(printf '00'; openssl rand -hex 31) | sudo docker secret create eez-devnet-relay-signing-key -
sudo docker volume create eez-devnet-414141-redis
sudo docker volume create eez-devnet-414141-postgres
sudo docker volume create eez-devnet-414141-pbs
sudo docker volume create eez-devnet-414141-builder
sudo docker volume create eez-devnet-414141-builder-beacon
sudo docker stack deploy --detach=true -c deploy/swarm/local/stacks/relay.yml eez-devnet-pbs
sudo docker service logs --tail 50 eez-devnet-pbs_relay-api
```

Require PostgreSQL and housekeeper readiness. The API waits for the housekeeper's
post-migration metrics endpoint. Read only the API's **public** BLS key from its
`Using BLS key` log, then replace `PUBLIC_BLS_KEY` below:

```sh
sudo env EEZ_DEVNET_RELAY_PUBLIC_KEY=PUBLIC_BLS_KEY docker stack deploy --detach=true \
  -c deploy/swarm/local/stacks/pbs-bootstrap.yml eez-devnet-pbs-bootstrap
sudo docker service ps eez-devnet-pbs-bootstrap_bootstrap --no-trunc
sudo docker service logs --tail 50 eez-devnet-pbs-bootstrap_bootstrap
```

Require bootstrap `Complete` before starting consumers. It records public peer,
relay and genesis-time bindings in the PBS volume.

## Start builder and boost

Build the pinned builder's shell wrapper once, if missing:

```sh
sudo docker build -f deploy/swarm/components/pbs/Dockerfile.builder \
  -t eez-devnet-builder:261124-pbs-v1 .
```

The public builder fixture `0xb9e79D19f651a941757b35830232E7EFC77E1c79` needs test
ETH for its configured 1 ETH bid subsidy. Fund it before testing. Never share
canonical datadirs with the builder or use fixture keys on Lark.

For fresh installation only, submit the one-shot fixture funding job with the
matching `EEZ_DEVNET_DEPLOY_IMAGE` selected:

```sh
sudo env EEZ_DEVNET_DEPLOY_IMAGE=YOUR_DEPLOY_IMAGE docker stack deploy --detach=true \
  --resolve-image never -c deploy/swarm/local/stacks/builder-fund.yml eez-devnet-builder-fund
sudo docker service ps eez-devnet-builder-fund_fund --no-trunc
```

Require `Complete`/exit 0 before continuing. Whole-devnet reset includes this step.

```sh
sudo docker stack deploy --detach=true --resolve-image never \
  -c deploy/swarm/local/stacks/builder.yml eez-devnet-builder
sudo docker stack deploy --detach=true -c deploy/swarm/local/stacks/boost.yml eez-devnet-boost
```

On a quiet fresh chain, submit the one-shot 0.01 test-ETH bundle canary to exercise
the builder, then check that delivery was canonical:

```sh
sudo env EEZ_DEVNET_DEPLOY_IMAGE=YOUR_DEPLOY_IMAGE docker stack deploy --detach=true \
  --resolve-image never -c deploy/swarm/local/stacks/pbs-canary.yml eez-devnet-pbs-canary
sudo docker service ps eez-devnet-pbs-canary_canary --no-trunc
```

Require canary `Complete`/exit 0. It waits for builder catch-up and nonempty relay
duties, then broadcasts once; it does not retry a missed target. Next:

```sh
sudo bash scripts/local-devnet.sh check-pbs
```

Require the check job to complete successfully. It matches an expected-builder
relay delivery against canonical L1, and checks builder consensus and relay/boost
health. It does not validate refunds or EEZ execution. The local bidder uses
`slot_delta_to_start_bidding_ms=-12000` so an early candidate can bid on a quiet chain.

## Operate and recover

Use [full-network `up` / `down`](../README.md#run-check-and-stop). Read tasks/logs
through Swarmpit or `sudo docker service ps` / `sudo docker service logs` for
`eez-devnet-pbs_relay-api`, `eez-devnet-pbs_relay-housekeeper` and
`eez-devnet-builder_builder`. An open builder RPC alone does not prove readiness;
require rollout completion before canary submission.

Database initialization runs only on an empty volume. Changing its secret or
database setting does not migrate an existing database or rotate its password.
Retain PostgreSQL, Redis AOF, PBS bindings, genesis and signing secrets for restart.
If peer/relay identities change, stop builder consumers and regenerate their
public bindings. Pending builder bundles are in memory and can be lost on restart.

For a logical backup, pause relay writers and run PostgreSQL 17
`pg_dump -Fc --no-owner --no-acl` from an owned Swarm task on
`eez-devnet-pbs_relay`. Read the password secret inside the task and store the dump
with umask 077. The shared PostgreSQL backup job does not cover this database.
Restore into an isolated instance with
`pg_restore --no-owner --no-acl --exit-on-error --single-transaction`; compare
schema/table counts before reconnecting writers. Retain paired Redis/key state.

Use the [validation guide](VALIDATION.md) for cross-chain checks and their scope.
