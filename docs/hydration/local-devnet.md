# Hydration on the server devnet

The server-local L2 profile selects Hydration rules version 1 at genesis,
with L1 chain ID 414141 and L2 chain ID 424242. It uses public Hardhat test
accounts for an isolated development network:

| Role | Account |
| --- | --- |
| Oracle updater | Account 2: `0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc` |
| PEPL keeper | Account 3: `0x90f79bf6eb2c4f870365e785982e1f101e93b906` |

`deploy/swarm/devnet/l2-deploy.sh` generates a copy of `genesis.dev.json` with
these roles in `config.hydration` and the counter account `0x...0800` seeded
with nonce 1, no balance, code or storage. Both role accounts already have test
ETH in the development base. The production and development base fixtures remain
unchanged. The ordinary genesis renderer and network-profile checks then bind
the genesis block and settlement profile into registration. Hydration roles
are additionally bound by the complete chain-document digest in RPC validation
identity; registration does not attest the signer's binary or every JSON field.

Composer and the independent ECDSA signer consume the same generated genesis.
All Hydration hooks activate together: counter execution, protocol-transaction
ordering and signer validation. Submit role transactions through the ordinary
L2 mempool. Cross-chain fronts reject protocol transactions intended for the
Live-block prefix. These roles are identities, not deployed oracle or PEPL
applications; application deployment is a separate step.

See the [local L2 runbook](../../deploy/swarm/devnet/L2.md) for build, deployment,
interfaces, counter/settlement canary and recovery procedures.
The [block production lifecycle](block-production-lifecycle.md) explains how
transactions move from local execution through signing and L1 settlement.

## Local validation

On 2026-11-26, local images built from Rust revision `5f8813d4` with the working
Swarm configuration deployed and registered rollup 1. The state-changing canary
incremented the counter from 0 to 1 in L2 block 550. The independent ECDSA signer
validated the 1–558 window, and the one-blob posting became canonical on L1 at
block 13022. An independent RPC check matched the on-chain commitment to
canonical L2 block 558 and rechecked the counter receipt/state.

This establishes local counter execution and settlement, not complete Hydration
protocol-ordering coverage, independent follower replay, restart recovery,
Chiado deployment or ZisK proving. Failed preflight/startup attempts and their
corrections are retained in the task record and Swarm history.

On 2026-11-27, a controlled stop/start at configuration revision `6cca9954`
reused those runtime images and genesis while stopping all 21 devnet services,
including the optional explorers. Counter value 3 and historical settlement
records survived; a new increment 3→4 settled canonically through L2 block 41628.
Both explorer indexes resumed. The [shared qualification record](../../deploy/swarm/devnet/VALIDATION.md)
contains evidence and limits. This qualifies that graceful restart with retained
volumes, not crash durability, durable queue recovery or an isolated restore.

This local fixture is the explicit exception to production role-key guidance:
public test keys may be used only on the isolated development network. Lark and
Chiado require separately provisioned accounts. Role changes require a fresh
network; there is no activation-height or existing-genesis migration path.
The ECDSA signer deployment does not enable a Hydration-aware ZisK prover or
governance-controlled runtime activation.
