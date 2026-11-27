# Shared Swarm components

These launchers contain no local chain IDs, funded accounts or signing keys.
The [local stacks](../local/stacks/) supply concrete inputs;
[Lark](../lark/README.md) must supply its own.

| Component | Required inputs and behavior |
| --- | --- |
| `pbs/relay-start.sh` | `EEZ_RELAY_DATABASE`: equal database/login name, 1–63 lowercase letters/digits/underscores, starting with a letter/underscore. Reads relay password, genesis metadata and API-only signing secret. Uses `postgres:5432`; post-migration housekeeper readiness gates API startup. |
| `pbs/provision-relay.sh` | Empty PostgreSQL volume and the same database/password inputs; creates the non-superuser role/database and revokes PUBLIC access. |
| `pbs/builder-start.sh` | Separate builder datadir, genesis/PBS bindings and Engine JWT; 60-million gas limit for this topology. |
| `pbs/boost-start.sh` | Genesis fork metadata and saved relay URL/time; 12-second slots. |
| `pbs/Dockerfile.builder` | Adds a shell to the pinned builder; no keys/configuration baked in. |
| `rollup/start.sh` | `node\|signer [trusted-env-file]`; verifies deployment checksums, exports bindings, then sources the optional role file. Otherwise uses inherited environment plus bindings. |
| `explorers/start.sh` | `EXPLORER_CHAIN=l1\|l2`, deployment documents, that backend's DB password and web secret. |
| `explorers/postgres-init.sh` | Empty explorer PostgreSQL volume and distinct secrets for `eez_l1_explorer` / `eez_l2_explorer`. |
| `explorers/nginx.conf.template` | Internal backend/frontend names; HTTP/API/WebSocket proxy, without host access policy. |

For Lark, mount separate trusted node/signer secret files and invoke
`sh /start.sh node /run/secrets/node-env` or
`sh /start.sh signer /run/secrets/signer-env`. Each role receives only its
required credentials. Ports, mount paths and slot timing still follow this topology.

Genesis/roles, peer bootstrap, builder funding, beacon fee recipients, host ports
and canaries remain environment-specific under `local/`.
