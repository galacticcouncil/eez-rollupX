#!/usr/bin/env bash
# Execute as an overlay-attached Swarm task using the genesis tool image.
set -euo pipefail
rpc() {
    curl -fsS --max-time 10 -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" http://execution:8545
}
[[ "$(rpc eth_chainId '[]' | jq -er .result)" == 0x651bd ]]
first="$(rpc eth_blockNumber '[]' | jq -er .result)"
sleep 24
second="$(rpc eth_blockNumber '[]' | jq -er .result)"
(( second > first )) || { echo 'Execution head did not advance'; exit 1; }
curl -fsS --max-time 10 http://beacon:5052/eth/v1/node/syncing | jq -e '.data.is_optimistic == false'
finalized="$(rpc eth_getBlockByNumber '["finalized",false]' | jq -er \
    'if has("error") then error("finality RPC failed") else (.result.number // "0x0") end')"
echo "L1 execution advanced from $first to $second; finalized block $finalized"
(( finalized > 0 )) || { echo 'Waiting for first non-genesis finality; rerun after two to three epochs.'; exit 2; }
