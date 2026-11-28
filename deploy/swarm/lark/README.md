# Lark staging

Private PoS L1 **686868**, EEZ L2 **696969**, deployed through the **Swarmpit API**.
[Network intent](../../networks/lark.example.json) records the selected IDs.

The scripted L1 bootstrap generates credentials and genesis, provisions only
`eez-lark-1-*` resources, starts execution/beacon/validator and waits for identity,
block advancement and finality. The PBS bootstrap adds the builder/relay path
and proves a private bundle reached canonical L1. L2 and explorers follow.
Source: [CLI](../../../scripts/lark-swarmpit.py), [lifecycle](lifecycle.py),
[runtime](l1.yml), [finite jobs](job.yml).

## Inspect the target

Use Python 3 with PyYAML. Store the API key in
`~/.config/lark-swarmpit-token`, owned by your user with mode `600`; enter it
through a hidden terminal prompt, not a shell argument. Supply the Swarmpit
HTTPS origin as `LARK_SWARMPIT_URL` (the browser's `/#/` suffix is also accepted).

```sh
python3 scripts/lark-swarmpit.py inspect --url "$LARK_SWARMPIT_URL"
```

The client reads nodes, services, stacks and networks. It reports node capacity,
current CPU/memory/disk statistics and service state. It excludes service
environments, configs, secrets and server error messages, and refuses redirects
so the administration token cannot follow them. Retain inventories outside Git.

## Bootstrap L1

From the repository root, select `LARK_DATA_NODE` from the inventory. Initial
provisioning currently requires a single active amd64 manager, because the
Swarmpit volume API creates local volumes on that manager. No node labels,
shared networks or unrelated service settings are changed.

```sh
sudo bash deploy/swarm/lark/tools.sh /tmp/eez-lark-tools
python3 scripts/lark-swarmpit.py bootstrap-l1 \
  --url "$LARK_SWARMPIT_URL" --node-id "$LARK_DATA_NODE" \
  --validator-tool /tmp/eez-lark-tools/eth2-val-tools
```

`tools.sh` extracts and verifies the mnemonic generator from the pinned genesis
image using a temporary container which is never started. Existing verified
tools are reused. The bootstrap uses Swarmpit for every remote operation.

Private credentials and operation state default to `~/.config/eez-lark-1/`
(directory `700`, credential/state files `600`); override with `--state-dir`
outside the checkout. Back up this directory securely. Never commit it or share
its mnemonic/JWT. The master mnemonic controls fresh validators and a preminted
treasury at Ethereum derivation index zero; later roles need their own secrets.
Only the preparation job mounts that mnemonic secret. Execution/beacon receive
the Engine JWT; public chain documents contain neither secret nor private logs.

The workflow claims preparation once, keeps private generator/key logs on the
validator volume and publishes an allowlist of public metadata. It refuses
partial genesis, missing ownership state, resource-name collisions and blind
POST retries after an uncertain response. Rerunning a confirmed submission waits
on the retained job; it does not regenerate or resubmit it. Inspect ambiguous
submissions before recovery. Initial finality can take 30 minutes; waits are
bounded by `--timeout` (default 3600 seconds). Timed-out jobs remain visible in
Swarmpit and do not restart automatically. CLI timeouts apply to each phase;
the readiness job itself has a one-hour deadline. Interrupting the CLI leaves
submitted Swarm jobs running; rerun it to observe confirmed submissions.

## Add builder and relay

After L1 passes readiness, extract Foundry from an existing, immutable deployment
tool image containing Foundry 1.7.1. This reuses the binary; it does not build or
publish an image. The extraction verifies the expected binary hash.

```sh
sudo bash deploy/swarm/lark/tools.sh /tmp/eez-lark-tools "$EEZ_DEPLOY_TOOL_IMAGE"
python3 scripts/lark-swarmpit.py bootstrap-pbs \
  --url "$LARK_SWARMPIT_URL" --cast /tmp/eez-lark-tools/cast
```

The workflow provisions dedicated PostgreSQL/Redis, waits for SQL readiness and
relay migrations, updates the beacon/validator, discovers public peers, funds
a fresh builder wallet and starts the builder.
The canonical beacon advertises its private overlay address in a signed ENR;
the builder uses it for rediscovery after a beacon restart. No public peer ports
are opened. Proposal/discovery settings are applied before starting the builder.
Funding and canary transactions are signed offline on the operator machine;
the treasury mnemonic never goes to these remote jobs. Signed bytes, nonce and
hash are saved before submission; uncertain outcomes never authorize a new
transaction. The private bundle targets one block and must match a canonical
receipt, builder coinbase and relay delivery. Ordinary local proposals cannot
pass this check. A failed attempt stays visible for diagnosis.

| Stack | Services and purpose |
| --- | --- |
| `eez-lark-1` | Execution, beacon and validator: canonical PoS chain |
| `eez-lark-1-pbs` | PostgreSQL/Redis: isolated relay storage; housekeeper: duties/migrations; API: bids and payload delivery |
| `eez-lark-1-builder` | Builder execution/beacon: construct payloads; mev-boost: forward bids and winning payloads |

Source: [PBS orchestration](pbs/lifecycle.py), [relay stack](pbs/relay.yml),
[builder stack](pbs/builder.yml), [builder policy](pbs/builder.template.toml).
All images are digest-pinned, all services have resource budgets and bounded
logs, and no ports are published. Relay storage uses its own overlay and volumes;
it never connects to a global database. New volumes are
`eez-lark-1-686868-{postgres,redis,pbs,builder,builder-beacon}`.

New private files in the same state directory hold database passwords, relay
and builder keys, a separate builder Engine JWT and the secret builder TOML.
Only the builder mounts its signing configuration; public peer metadata contains
no keys. The builder starts with 1000 private-chain test ETH and bids with a
0.01 test ETH subsidy. This is staging policy, not application fee economics.

PBS upgrades operation state to schema 2 and keeps a private `state-before-pbs.json`
backup. Use this revision's helper for subsequent operations: older L1-only
helpers reject the new state. Do not restore the schema-1 backup while PBS is
installed. Proposal settings, genesis, credentials and data must stay consistent;
there is no automatic downgrade or destructive reset.

## Daily operation

Use the same target and state directory:

```sh
python3 scripts/lark-swarmpit.py status --url "$LARK_SWARMPIT_URL"
python3 scripts/lark-swarmpit.py down --url "$LARK_SWARMPIT_URL"
python3 scripts/lark-swarmpit.py up --url "$LARK_SWARMPIT_URL"
python3 scripts/lark-swarmpit.py check --url "$LARK_SWARMPIT_URL"
```

Stop orders validator → boost/builder → relay/storage → canonical beacon/execution;
start restores dependencies before the validator. Both retain volumes,
credentials, images and saved configuration and control only these ten services.
Before PBS installation the same commands control the three L1 services.
The old `l1-start`/`l1-stop` commands refuse once PBS is installed.
New checks are read-only finite Swarm jobs with retained logs. Inspect EEZ task
health/logs in Swarmpit; preparation traces live privately at
`/validators/preparation/` in its volume. Public readiness checks bind execution
genesis and consensus root/time to the preparation receipt.
With PBS installed, checks also verify builder sync, validator registration,
the retained canonical canary receipt and a canonical relay delivery from the
same builder. An idle builder need not produce empty bids. These checks do not
submit another bundle or prove a fresh post-restart submission.

To exercise the full builder path after a start, submit an explicit private probe:

```sh
python3 scripts/lark-swarmpit.py probe-pbs \
  --url "$LARK_SWARMPIT_URL" --cast /tmp/eez-lark-tools/cast
```

It signs one 0.01 test ETH transfer to the builder, submits only a single-target
private bundle and checks its canonical receipt, coinbase and relay delivery.
Each completed start cycle has one probe; repeats resume the same recorded bytes
or return its retained proof. A no-op `up` does not create another cycle. Retained
probe evidence is historical; use `check` for current sync/registration health.
If readiness stalls, `diagnose --url "$LARK_SWARMPIT_URL"` runs a finite job
reporting public EL/CL heads and peer connections, without chain writes. Retain
its output outside Git; it includes private-network addresses.
After fixing a confirmed pre-submission readiness timeout, `retry-canary --url
"$LARK_SWARMPIT_URL"` permits one recovery job with the same signed bytes and
nonce. It retains the original failed task and refuses a job that may already
have submitted a bundle. Other canary failures require explicit diagnosis.

Saved Swarmpit stack and live EEZ configuration fingerprints must match local
operation state before replica changes. Reconcile intentional UI edits with the
source and state first. No automatic reset, rekeying or volume deletion is
provided. Restore matching state/keys/volumes through an explicit recovery task;
do not regenerate them to repair a failed bootstrap. This is not high availability
or a qualified backup/restore procedure.

## Preview the initial L1

Select the persistent node ID from the inventory and a fresh Lark fee-recipient
address. Explicit arguments determine the rendered values; process environment
does not override them. Local funded fixture addresses are rejected.

```sh
python3 scripts/lark-swarmpit.py render-l1 \
  --node-id "$LARK_DATA_NODE" --fee-recipient "$LARK_FEE_RECIPIENT" \
  > /tmp/lark-l1.json
sudo docker stack config -c /tmp/lark-l1.json
```

Output is a Compose document encoded as JSON. It uses the same pinned Reth and
Lighthouse images as local, with CPU/memory budgets, bounded logs, stop-first
updates and no published ports. Persistent services are pinned to the selected
node; no existing node labels or unrelated services are changed.

The intended stack name is `eez-lark-1`, with overlay `eez-lark-1_l1`, external
volumes `eez-lark-1-686868-{genesis,execution,beacon,validators}` and external
secrets `eez-lark-1-engine-jwt` and `eez-lark-1-validator-mnemonic`. The bootstrap
provisions these on the selected node. Genesis must be generated for chain
686868 and match the funded treasury and new validator/slashing state. Copying
local genesis, validators, funded fixtures or writable volumes is unsupported.
The chain ID comes from the prepared genesis, not the stack/volume name.

The initial L1 preview uses ordinary validator proposals. `bootstrap-pbs` saves
and checks the explicit transition to builder proposals. PBS alone still does
not deploy EEZ contracts or L2.

## Remaining deployment work

Reuse the [shared components](../components/README.md) and
[local topology](../local/README.md), with stack-contained PostgreSQL/Redis
and both explorers. The remaining prerequisites are:

- Verified published node/signer/deploy digests and compatible explorer images.
  Build/testing remains separate from deployment.
- Hydration roles and signer/poster/relay/builder keys, in role-specific secrets.
- Private DNS/TLS access and the L2/explorer stack resources.
- A deployment bundle binding both chain IDs;
  local genesis/deployment scripts still encode local IDs and roles.
- Staging fee assumptions, backup/restore and admission checks.
- L2/explorer API provisioning/reconciliation, then fresh execution, cross-chain/blob,
  explorer and recovery validation.

Retain private overlays, external volumes, stop-first single writers and bounded
logs. Public local fixture keys and synthetic fee assumptions are not staging
inputs. Editing intent JSON cannot produce a deployment or alter an existing chain.
The initial backend is ECDSA; ZisK and runtime governance need separate integration.

For an existing network, retain its genesis, keys, volumes and data-node
placement. Applying new IDs or genesis is a fresh network, not a migration.
New preflight/render tooling does not update existing services. Restore the
previous matching stack/configuration for rollback; never regenerate validator
or deployment state to recover a failed rollout.
