# Lark staging

Private PoS L1 **686868**, EEZ L2 **696969**, deployed through the **Swarmpit API**.
There is no executable Lark stack or API deployer yet.
[Network intent](../../networks/lark.example.json) records the selected IDs.

Reuse the [shared components](../components/README.md) and
[local topology](../local/README.md), including stack-contained PostgreSQL/Redis
and both explorers. Assembly still needs:

- Verified published node/signer/deploy digests and compatible explorer images.
  Build/testing remains separate from deployment.
- Its own genesis, validator/slashing state, Engine JWT, funded accounts,
  Hydration roles and signer/poster/relay/builder keys, in role-specific secrets.
- Stack/network/volume names, data-node placement and private DNS/TLS access.
- Builder/peer configuration and a deployment bundle binding both chain IDs;
  local genesis/deployment scripts still encode local IDs and roles.
- Staging fee assumptions, backup/restore and admission checks.
- Swarmpit API reconciliation, then fresh execution, cross-chain/blob,
  explorer and recovery validation.

Retain private overlays, external volumes, stop-first single writers and bounded
logs. Public local fixture keys and synthetic fee assumptions are not staging
inputs. Editing intent JSON cannot produce a deployment or alter an existing chain.
The initial backend is ECDSA; ZisK and runtime governance need separate integration.
