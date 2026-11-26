#!/usr/bin/env bash
set -euo pipefail
umask 022
[[ "$(cast chain-id --rpc-url http://execution:8545)" == 414141 ]]
[[ -z "$(find /out -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
    echo 'Deployment state exists; inspect receipts before recovery. Refusing a second broadcast.' >&2
    exit 1
}
# Atomic persistent claim: a failed/partial deployment is never retried automatically.
mkdir /out/deployment-started
install -m 0644 /genesis/metadata/genesis.json /out/l1-genesis.json
set -a
source /l2-fixtures.env
set +a
jq '.config.chainId = 424242 |
    .config.hydration = {rulesVersion: 1,
      oracleUpdater: "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc",
      peplKeeper: "0x90f79bf6eb2c4f870365e785982e1f101e93b906"} |
    .alloc["0x0000000000000000000000000000000000000800"] = {nonce: "0x1", balance: "0x0"}' \
    /repo/genesis.dev.json > /out/genesis.base.json
export EEZ_L1_RPC_URL=http://execution:8545
export EEZ_L1_CHAIN_CONFIG=/out/l1-genesis.json
export EEZ_L1_REFERENCE=finalized
export EEZ_L1_BLOCK_TIME_MS=12000 EEZ_L2_BLOCK_TIME_MS=2000
export EEZ_GENESIS_BASE=/out/genesis.base.json
export EEZ_GENESIS_OUT=/out/l2-genesis.json
export EEZ_DEPLOYMENTS_FILE=/out/deployments.env
bash /repo/scripts/deploy.sh
jq -e '.config.chainId == 424242 and .config.hydration.rulesVersion == 1 and
    .alloc["0x0000000000000000000000000000000000000800"].nonce == "0x1"' \
    /out/l2-genesis.json >/dev/null
sha256sum /out/l1-genesis.json /out/l2-genesis.json /out/l2-genesis.profile.json /out/deployments.env > /out/deployment.sha256
touch /out/deployment-complete
echo 'Deployed and registered local Hydration L2 424242 on L1 414141.'
