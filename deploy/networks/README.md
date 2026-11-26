# Network planning

The promotion path is local qualification (Kurtosis tests and the server Swarm
devnet), persistent Lark staging with its own private Ethereum PoS L1, then a
public Chiado L2. Lark infrastructure
hosts staging; the Hydration Lark chain is not the settlement chain.

This first slice validates network intent and joins it with the existing
[CI runtime manifest](../../scripts/ci/build-runtime-artifacts.sh). Python 3 and
Git are sufficient; Docker, RPC access and credentials are not needed.

For the running server-local L1, use the
[Swarm devnet lifecycle](../swarm/devnet/README.md),
[builder/PBS](../swarm/devnet/PBS.md) and [L2](../swarm/devnet/L2.md) runbooks.
L1 414141 and L2 424242 are running with local counter settlement verified.
Remaining work includes cross-chain/replay qualification, portable Lark inputs,
explorers and direct Swarmpit API deployment.

```sh
python3 scripts/network-plan.py deploy/networks/lark.example.json /path/to/runtime/manifest.json
```

Choose the local or Chiado example for those environments. Local IDs are
414141/424242; selected Lark IDs are 686868/696969. Each new network must bind its
intended IDs into genesis; changing an intent file cannot change an existing chain.
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
paths. The local Swarm definitions are executable independently of this planner;
a manifest-driven Lark lifecycle via the Swarmpit API is still to be implemented.

Reuse the working local PoS L1/PBS/L2 topology, with persistent external volumes,
Swarm secrets and stop-first single-writer updates. Deployment is driven directly
through the Swarmpit API using an operator API key, not a CI deployment job.
Image preparation/testing remains separate. Complete the remaining
configuration, validation, explorer and recovery work before developer handoff.
Governance activation and ZisK proving require their own runtime integration;
the initial staging proof backend is ECDSA.

Promote the same image digests between environments. Each environment has its own
genesis, deployment addresses, keys and chain identity. A new plan creates no
migration or rollback capability for an existing chain. Preserve its original
release and deployment bundle for restart/replay; follow its owning runbook for
compatible upgrades. Unknown schema versions must be rejected by older planners.
