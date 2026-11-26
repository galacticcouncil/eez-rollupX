# Network planning

The promotion path is disposable local Kurtosis, persistent Lark staging with
its own private Ethereum PoS L1, then a public Chiado L2. Lark infrastructure
hosts staging; the Hydration Lark chain is not the settlement chain.

This first slice validates network intent and joins it with the existing
[CI runtime manifest](../../scripts/ci/build-runtime-artifacts.sh). Python 3 and
Git are sufficient; Docker, RPC access and credentials are not needed.

For the running server-local L1, use the
[Swarm devnet lifecycle](../swarm/devnet/README.md). It currently covers L1
414141; the EEZ L2 424242 and builder path are still pending integration.

```sh
python3 scripts/network-plan.py deploy/networks/lark.example.json /path/to/runtime/manifest.json
```

Choose the local or Chiado example for those environments. Example names and
chain IDs are placeholders to review for each new network, not reservations.
Output is deterministic JSON on stdout; failures return nonzero without echoing
input contents. The command performs no network access or writes.

## Network manifest schema 1

All five fields are required, with no additional fields:

| Field | Contract |
| --- | --- |
| `schema` | Integer 1 |
| `name` | Lowercase letter followed by up to 39 lowercase letters, digits or hyphens |
| `environment` | `local`, `lark`, or `chiado` |
| `l1_chain_id` | Positive uint64; Chiado requires 10200; private environments reject 1, 100 and 10200 |
| `l2_chain_id` | Positive uint64, distinct from L1 |

There are no environment-variable overrides. Credentials, JWTs, authenticated
URLs and operational state belong outside this public intent file. The planner
does not render runtime configuration yet, so these fields do not currently
reach any node, signer, Compose or Swarm consumer.

## Release input and guarantees

Supply CI's existing schema-2 `manifest.json`, preserving its bytes as evidence.
The planner checks source HEAD, the committed Core gitlink and Cargo.lock hash,
linux/amd64 release profile, and the three node/signer/deploy image identities.
Lark and Chiado require published digest references. Local planning also permits
CI's unpublished images; those require the producer's Docker daemon and image-ID
verification before execution. No new release manifest format is introduced.

The plan records both input SHA-256 hashes and preserves the selected image
references. A manifest is an assertion, not a signature: acceptance does not
prove CI passed, image labels match, binaries exist, or registry access works.
Execution must use the existing artifact verification contract in
[prepare-runtime-artifacts.sh](../../scripts/ci/prepare-runtime-artifacts.sh),
plus completed CI qualification, before treating those artifacts as trusted.
The planner does not accept raw manifests as authorization to deploy.

## Next lifecycle stages

The output's backend is intended orchestration: Kurtosis locally and Swarm for
persistent Lark/Chiado. Existing [Kurtosis](../../testing/kurtosis/README.md) and
[Chiado](../../docs/runbooks/chiado-deployment.md) procedures remain the executable
paths; a Swarm backend has not been implemented by this slice.

Next implement the Lark private PoS L1/PBS topology with persistent external
volumes, Swarm secrets and stop-first single-writer updates. Then add deployment
receipt reconciliation, rendered genesis/bindings, start/status/verification,
and backup/restore exercises. Public endpoints follow core qualification.
Governance activation and ZisK proving require their own runtime integration;
the initial staging proof backend is ECDSA.

Promote the same image digests between environments. Each environment has its own
genesis, deployment addresses, keys and chain identity. A new plan creates no
migration or rollback capability for an existing chain. Preserve its original
release and deployment bundle for restart/replay; follow its owning runbook for
compatible upgrades. Unknown schema versions must be rejected by older planners.
