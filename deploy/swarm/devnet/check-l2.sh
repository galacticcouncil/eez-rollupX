#!/usr/bin/env bash
# Read-only readiness check; the separate canary tests new settlement.
set -euo pipefail
test -f /out/deployment-complete
sha256sum -c /out/deployment.sha256 >/dev/null
rpc() {
    curl -fsS --max-time 10 -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" \
        http://eez-node:18688 | jq -e 'if has("error") then error("L2 RPC failed") else .result end'
}
[[ "$(rpc eth_chainId '[]' | jq -r .)" == 0x67932 ]]
first=$(rpc eth_blockNumber '[]' | jq -r .)
sleep 4
second=$(rpc eth_blockNumber '[]' | jq -r .)
((second > first)) || { echo 'L2 head did not advance.' >&2; exit 1; }
curl -fsS --max-time 10 http://eez-beacon:5252/eth/v1/node/syncing |
    jq -e '.data.is_syncing == false and .data.is_optimistic == false and .data.el_offline == false' >/dev/null
counter=$(rpc eth_call '[{"to":"0x0000000000000000000000000000000000000800","data":"0x6d4ce63c"},"latest"]' | jq -r .)
[[ "$counter" =~ ^0x[0-9a-fA-F]{64}$ ]]
safe=$(rpc eth_getBlockByNumber '["safe",false]' | jq -er .number)
((safe > 0)) || { echo 'L2 safe head is still genesis.' >&2; exit 1; }
echo "L2 424242 advanced $first -> $second; safe=$safe; Hydration counter=$counter"
