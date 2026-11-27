# Hydration on the local devnet

L1 **414141**, L2 **424242**, Hydration rules version 1 from genesis.
This isolated network uses public Hardhat fixture accounts:

| Role | Account |
| --- | --- |
| Oracle updater | Account 2: `0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc` |
| PEPL keeper | Account 3: `0x90f79bf6eb2c4f870365e785982e1f101e93b906` |

The [deployment script](../../deploy/swarm/local/scripts/l2-deploy.sh) copies
`genesis.dev.json`, sets these funded roles in `config.hydration` and seeds
counter `0x…0800` with nonce 1, zero balance and no code/storage. Base fixtures
remain unchanged. Registration binds genesis/settlement profile; the RPC
validation identity additionally binds the complete chain document.
Registration does not attest the signer's binary or every JSON field.

Composer and the independent ECDSA signer consume the same genesis. Counter,
protocol-prefix and signer hooks activate together. Submit role transactions
through the ordinary L2 mempool; cross-chain fronts reject protocol transactions
intended for the Live-block prefix. Roles identify authorities; oracle/PEPL
applications still need deployment.

Use the [Swarm lifecycle](../../deploy/swarm/local/README.md) and
[L2 runbook](../../deploy/swarm/local/docs/L2.md) for commands; the
[block lifecycle](block-production-lifecycle.md) explains execution and settlement.

## Local validation

Use the [counter canary](../../deploy/swarm/local/docs/L2.md#counter-canary) for
counter execution and settlement, and the
[cross-chain checks](../../deploy/swarm/local/docs/VALIDATION.md) for bidirectional
and nested calls. These do not establish complete Hydration ordering coverage,
independent follower replay, crash/queue durability, restore or Chiado deployment.

Public fixture keys are local-only; Lark/Chiado require separate accounts.
Role/chain changes require a fresh network. There is no activation-height or
existing-genesis migration path. This deployment enables neither Hydration-aware
ZisK proving nor governance-controlled runtime activation.
