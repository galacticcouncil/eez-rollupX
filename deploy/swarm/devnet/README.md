# Server development L1

First stage of the server devnet/Lark deployment path: private Ethereum PoS L1,
L1 chain ID 414141, L2 chain ID 424242, 12-second slots, 64 validators, Fulu and BPO1 from genesis
(15 maximum / 10 target blobs). Mainnet preset epochs remain 32 slots.
The [builder/PBS stack](PBS.md) extends this L1. The [EEZ L2 runbook](L2.md)
adds the local Hydration network. L1 health alone does not establish EEZ
cross-chain settlement. The production chain/profile and Core pin are unchanged.

The fixtures use the public `test ... junk` mnemonic and fund its first EVM
account with test ETH. Use this stack only as an isolated development network;
Lark staging needs separately provisioned validator keys and accounts. The Engine
JWT is generated independently and mounted as a Swarm secret.

## Daily use: the complete installed devnet

After L1, PBS and L2 have been provisioned, run from the repository root:

```sh
sudo bash scripts/local-devnet.sh down
sudo bash scripts/local-devnet.sh up
sudo bash scripts/local-devnet.sh status-all
sudo bash scripts/local-devnet.sh check-all
```

`down` stops all 13 runtime services in dependency order, waiting for actual
tasks to stop: Composer first, validator next, remaining consumers, canonical
beacon, then execution/PostgreSQL/Redis. `up` resumes those same services in
reverse dependency groups. It needs no image overrides and never reruns genesis,
bootstrap, funding or contract deployment. Existing images, volumes, secrets,
validator signing history and deployment records remain paired.

Both commands require a complete installation before changing anything and wait
up to 180 seconds per group (`EEZ_DEVNET_WAIT_SECONDS`, positive 1–9999). A timeout
stops the command and reports the service; inspect its tasks/logs before retrying.
Run one lifecycle operation at a time. `up` waits for running tasks, while
`check-all` submits a separate finite readiness job; require its successful exit.
That job checks L1 advancement/finality, PBS, L2 advancement, saved configuration,
the counter read and a non-genesis safe head. It does not broadcast a transaction.

The original `start`/`stop` commands below control **L1 only**, and `l2-start` /
`l2-stop` control L2 only. Use `up` / `down` for daily whole-network operation.
Use provisioning commands only for first setup, not to resume an existing chain.
Unsettled requests and retry counters remain in memory; clients may need to
resubmit work after restart.

On 2026-11-26, complete `down` / `up` passed on the same volumes. Checks preserved
settled L2 block 1368, counter value 2, the prior receipt and settlement correlation;
a fresh counter increment 2 → 3 settled through L2 block 2208. This was a controlled
stop/start, not a crash, overnight-outage or backup/restore exercise.

## Storage limits

All checked-in runtime/setup services and lifecycle probes use Docker `json-file`
logging with `max-size=20m` and `max-file=3`: approximately 60 MB per task.
The builder defaults to `info` logging. Limits apply to new tasks, including
replacements; they do not retroactively shrink old container logs. Retained
diagnostic jobs and service histories still consume space. Archive required
failure evidence before removing a specific old task; do not run broad pruning.

Compiler caches are separate from chain data. On 2026-11-26, removing only the
two unused EEZ node/signer BuildKit target-cache records reclaimed 8.3 GB;
images, Cargo registry caches, host `target/`, chain data and recovery volumes
were preserved. A future source build will recreate compiler caches. To reclaim
them again, inspect `sudo docker buildx du --format json`, identify reclaimable
records whose descriptions name `/eez-node-target` or `/eez-proof-signer-target`,
and prune only their exact IDs with both `id=...` and `type=exec.cachemount`
filters. Do not prune caches while builds are running. No daemon-wide GC policy
is installed because this server also builds unrelated services.

Measure physical allocation with `du`, not just apparent database file size:
sparse files can report gigabytes while allocating only megabytes. Witness
cleanup already follows the L1-finalized L2 floor; do not delete witness or
chain databases to manage routine disk usage. Pair future pruning changes with
replay/recovery validation. Explorers will add their own index storage.

## Lifecycle command

From the repository root, `sudo bash scripts/local-devnet.sh` accepts:

- `prepare`: create dedicated volumes/JWT and submit genesis preparation once.
- `start`: require completed preparation, then start/restart the existing chain.
- `status`: list L1-related services and their task state.
- `check`: submit a finite overlay health job, retrying for up to about 48 minutes
  for first finality. It prints the job name and commands to inspect its result.
- `stop`: scale all three runtime services to zero, retaining volumes and secrets.

Preparation and checks are asynchronous; submission success alone is not a
passing result. The equivalent commands and expected results follow below.

## Prepare once

Requires Docker Swarm on this server, `platform.data=true` on its data node,
OpenSSL, Bash, and permission to operate Docker. Run from this directory:

```sh
sudo docker volume create eez-devnet-414141-genesis
sudo docker volume create eez-devnet-414141-validators
sudo docker volume create eez-devnet-414141-execution
sudo docker volume create eez-devnet-414141-beacon
openssl rand -hex 32 | sudo docker secret create eez-devnet-engine-jwt -
sudo docker stack deploy -c prepare.yml eez-devnet-414141-prep
sudo docker service ps eez-devnet-414141-prep_prepare --no-trunc
sudo docker service logs eez-devnet-414141-prep_prepare
```

Require task completion and `Prepared private L1 genesis and 64 fixture validators`.
The generator and keystore traces remain in the private genesis volume.
The task refuses nonempty volumes, including partially generated state. Never
rerun it against an existing chain. After a failure inspect state before deciding
whether to recover or create a separately named network.

Generator image is version 5.2.5, pinned by digest. Its interface is documented
in the [release source](https://github.com/ethpandaops/ethereum-genesis-generator/tree/v5.2.5).
Reth and Lighthouse digests match the existing Kurtosis devnet profile.

## Start, inspect and stop

```sh
sudo docker stack deploy -c stack.yml eez-devnet
sudo docker service ls --filter name=eez-devnet
sudo docker service logs --tail 50 eez-devnet_execution
sudo docker service logs --tail 50 eez-devnet_beacon
sudo docker service logs --tail 50 eez-devnet_validator
```

Services are visible in Swarmpit. All RPC/Engine/beacon interfaces stay on the
`eez-devnet_l1` overlay, with no published host ports. Each writer has a dedicated
external volume and one replica, pinned to the data node. Updates stop the old
task first. Do not scale the validator or run a second copy of its keys.

Run the semantic health probe as an overlay-attached task; use a new probe name
for each run and keep its result until collected:

```sh
sudo docker config create eez-devnet-check-v3 check.sh
sudo docker service create --detach=true --name eez-devnet-414141-check-next --restart-condition none \
  --log-driver json-file --log-opt max-size=20m --log-opt max-file=3 \
  --network eez-devnet_l1 --config source=eez-devnet-check-v3,target=/check.sh \
  --entrypoint bash \
  ethpandaops/ethereum-genesis-generator@sha256:017f8bdbd454d2fcf4e0f65f6c64b5bc4c991f5846220e9be188145fa85875db /check.sh
sudo docker service ps eez-devnet-414141-check-next --no-trunc
sudo docker service logs eez-devnet-414141-check-next
```

The probe checks chain identity, execution advancement, nonoptimistic beacon
state and nonzero finalized execution height. Exit 2 means finality is still
pending; allow several epochs after successful block production. The first
414141 check exhausted its 24-minute budget before non-genesis finality was
observed; later beacon state confirmed finalized epoch 4. The lifecycle helper
therefore allows 48 minutes, retaining failure evidence from earlier checks.
Container readiness alone does not establish finality or blob availability.

To stop while retaining state:

```sh
sudo docker service scale eez-devnet_validator=0 eez-devnet_beacon=0 eez-devnet_execution=0
```

This example stops L1 only. For the complete installed devnet, use `down` above.

Restart using the same stack, volumes and JWT. Genesis and validator slashing
history must remain paired. There is no automatic reset or supported chain
migration. Before a destructive reset, stop every consumer, retain required
evidence and explicitly authorize the exact four volumes and JWT to replace.
Never regenerate genesis beneath existing execution or consensus datadirs.

The initial live deployment used chain 7331. On 2026-11-24 it was stopped and
replaced by chain 414141 using fresh `eez-devnet-414141-*` volumes. The original
volumes remain available for recovery. The existing Engine JWT secret is reused.

Backups must copy stopped execution/beacon/validator/genesis volumes together,
retain the JWT securely and record image digests and source revision. Restore
in isolation; never run two validator copies. No backup/restore exercise has
been completed for this stack yet. Single-node storage provides no HA.
