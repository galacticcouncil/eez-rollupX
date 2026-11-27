#!/usr/bin/env bash
# State-changing local test; all signing identities are public fixtures.
set -euo pipefail
test -f /out/deployment-complete
sha256sum -c /out/deployment.sha256 >/dev/null
source /l2-fixtures.env
export EEZ_USE_LOCAL_DEPLOYMENTS=1
export EEZ_DEPLOYMENTS_FILE=/out/deployments.env
export EEZ_L2_GENESIS=/out/l2-genesis.json
export EEZ_L1_CHAIN_CONFIG=/out/l1-genesis.json
export EEZ_DEVNET_L1_RPC=http://execution:8545
export EEZ_DEVNET_L2_RPC=http://eez-node:18688
export EEZ_DEVNET_L1_FRONT=http://eez-node:18999
export EEZ_DEVNET_L2_FRONT=http://eez-node:18998
export EEZ_L1_BEACON_URL=http://beacon:5052
export EEZ_CI_RESULT_DIR=/evidence
export EEZ_PROTOCOL_SCENARIOS='counter counterL2 nestedCounter'
export EEZ_PROTOCOL_MAX_PARALLEL=1
export EEZ_PROTOCOL_VERIFY_WORKERS=1
export EEZ_PROTOCOL_SUITE_TIMEOUT=1800

[[ "$(timeout 10 cast chain-id --rpc-url "$EEZ_DEVNET_L1_RPC")" == 414141 ]]
[[ "$(timeout 10 cast chain-id --rpc-url "$EEZ_DEVNET_L2_RPC")" == 424242 ]]
# A fresh external evidence volume prevents overwriting a preceding run.
mkdir /evidence/started
trap 'status=$?; printf "%s\n" "$status" > /evidence/exit-code' EXIT

# Use the runner's existing public account #2, separate from the poster.
export PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
sender=$(cast wallet address --private-key "$PK")
balance=$(timeout 10 cast balance "$sender" --rpc-url "$EEZ_DEVNET_L1_RPC")
if (( $(echo "$balance < 5000000000000000000" | bc) )); then
    # Three workers receive 1 test ETH each; retain setup/gas headroom.
    funding=$(timeout 20 cast send "$sender" --value 5ether --gas-limit 21000 \
        --private-key "$EEZ_L1_POSTER_KEY" --rpc-url "$EEZ_DEVNET_L1_RPC" --async)
    printf '%s\n' "$funding" > /evidence/funding-transaction
    timeout 120 cast receipt "$funding" --confirmations 1 --json \
        --rpc-url "$EEZ_DEVNET_L1_RPC" > /evidence/funding-receipt.json
    jq -e '.status == "0x1"' /evidence/funding-receipt.json >/dev/null
fi
forge --version > /evidence/foundry-version
sha256sum /usr/local/bin/e2e-causal-verify /usr/local/bin/verify_blob_evidence \
    > /evidence/verifiers.sha256
git rev-parse HEAD > /evidence/configuration-revision
git -C eez-core-protocol rev-parse HEAD > /evidence/protocol-revision
bash testing/kurtosis/scripts/run-protocol-e2e.sh
