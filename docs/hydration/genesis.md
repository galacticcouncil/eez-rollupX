# Hydration genesis and deployment

Neither bundled base contains a `config.hydration` section, so a default
deployment runs the stock rules. A Hydration network adds the section beside
`config.rollupX` in its base genesis, together with the counter account it
requires. Merged into the base, the additions are:

```json
{
  "config": {
    "hydration": { "rulesVersion": 1, "oracleUpdater": "0x…", "peplKeeper": "0x…" }
  },
  "alloc": {
    "0x0000000000000000000000000000000000000800": { "nonce": "0x1" }
  }
}
```

The section switches on Hydration's counter precompile and its
protocol-transaction ordering for the two role accounts. Its exact format,
checks and compatibility rules are in the
[signer specification](../../crates/eez-proof-signer/SPEC.md#3-startup-configuration).

- **Role accounts.** Name accounts whose keys you hold, never public
  development keys, and fix them before deployment. The section is part of the
  genesis document, and so of the validation identity. It cannot be added,
  removed or changed later.
- **Gas.** The production base allocates no ETH, so the role accounts need L2
  gas from elsewhere.
- **Submission.** Submit oracle updates and keeper transactions as ordinary L2
  transactions, which the payload builder places in the protocol prefix of a
  Live block. If one is routed through the L2 cross-chain front to be held for
  a Sync block, the front rejects it, because a Sync block cannot place it in
  the protocol prefix.
- **Binaries.** Deploy Hydration-capable Composer, follower and signer images
  from network creation. Images without this support reject the genesis, and
  rolling back to them stops the network.

Deployment with this section has not been exercised. Before any broadcast,
render the base with `scripts/update-eezl2-genesis.sh --render … --base PATH`
(the script's usage lists the required arguments) and check that the output
keeps the section and the counter account.
