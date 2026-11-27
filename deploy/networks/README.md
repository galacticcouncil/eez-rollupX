# Network planning

Qualification moves from the [local Swarm devnet](../swarm/local/README.md) to
[Lark staging](../swarm/lark/README.md), then public Chiado.
Lark uses its own private Ethereum PoS L1; the Hydration Lark chain is not the
settlement chain. Lark deployment will use the Swarmpit API, separately from CI
image preparation/testing.

| Environment | L1 ID | L2 ID |
| --- | --- | --- |
| Local | 414141 | 424242 |
| Lark | 686868 | 696969 |
| Chiado | 10200 | Selected per deployment |

## Validate intent

From the repository root, with Python 3, Git and CI's schema-2 runtime manifest:

```sh
python3 scripts/network-plan.py deploy/networks/lark.example.json /path/to/runtime/manifest.json
```

Choose the local or Chiado example as appropriate. Output is deterministic JSON;
errors return nonzero without echoing input contents. No network access or writes
occur. This planner **does not render stacks or deploy anything**.

Network schema 1 requires exactly these fields, without environment overrides:

| Field | Contract |
| --- | --- |
| `schema` | Integer 1 |
| `name` | Lowercase letter, then up to 39 lowercase letters, digits or hyphens |
| `environment` | `local`, `lark` or `chiado` |
| `l1_chain_id` | Positive uint64; Chiado requires 10200; private environments reject 1, 100 and 10200 |
| `l2_chain_id` | Positive uint64, distinct from L1 |

Keep credentials and operational state outside intent files. Their IDs do not
currently reach runtime consumers; changing JSON cannot change an existing chain.

## Artifact contract

The planner checks source HEAD, committed Core gitlink, Cargo.lock hash,
linux/amd64 release profile and node/signer/deploy image identities. It records
both input SHA-256 hashes and preserves image references. Lark/Chiado require
published digests; local planning also accepts CI's unpublished images, which
need their producer daemon and image-ID verification.

A manifest is an assertion, not CI attestation. Preserve its original bytes;
require completed CI qualification and the existing
[artifact verifier](../../scripts/ci/prepare-runtime-artifacts.sh) before execution.
Promote the same tested digests between environments, with separate genesis,
keys and deployment bundles. Plans provide no migration or rollback mechanism.
Unknown schema versions are rejected. See [Lark inputs](../swarm/lark/README.md)
for L1 bootstrap and the remaining PBS/L2/explorer assembly work.
