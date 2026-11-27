# Swarm layout

| Directory | Purpose |
| --- | --- |
| [components/](components/README.md) | Reusable PBS, node/signer and explorer startup code |
| [local/](local/README.md) | L1 414141 / L2 424242 stacks, fixtures, setup, checks and tests |
| [lark/](lark/README.md) | L1 686868 / L2 696969 staging requirements; assembly pending |

Under `local/`, `stacks/` defines services/setup jobs, `scripts/` owns genesis and
deployment, `fixtures/` holds public test inputs, `checks/` holds probes/canaries,
`access/` holds the private-port firewall helper and `docs/` holds runbooks.
Use the [scripts/local-devnet.sh](../../scripts/local-devnet.sh) entrypoint.

## Deployment compatibility

Source relocation does not update running tasks. Existing stack, service,
network, volume and secret names are retained; no data moves.
An explicit [whole-devnet reset](local/README.md#reset-the-whole-devnet) instead
discards current local state and installs these definitions from scratch.

Changed launchers use immutable configs `relay_start_v4`, `postgres_init_v2`
and `start_v3`. Apply complete stack definitions together with their inputs:
the relay requires `EEZ_RELAY_DATABASE` (locally still `eez_devnet_relay`);
the local rollup launcher explicitly receives its public fixture env file,
applied after deployment bindings.

Existing PostgreSQL volumes skip initialization. Changing the database setting
does not rename data or migrate roles. Rollback requires retained older configs
and matching definitions. Restart may discard in-memory queues.

Run the [validation checks](local/docs/VALIDATION.md) after deployment.
