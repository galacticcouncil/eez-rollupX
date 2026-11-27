#!/usr/bin/env bash
# Read-only proof that a relay-delivered builder payload became canonical.
set -euo pipefail
rpc() {
    curl -fsS --max-time 10 -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" "http://$3:8545"
}
for host in execution builder; do
    [[ "$(rpc eth_chainId '[]' "$host" | jq -er .result)" == 0x651bd ]]
done
curl -fsS --max-time 10 http://builder-beacon:5052/eth/v1/node/syncing | \
    jq -e '.data.is_syncing == false and .data.is_optimistic == false' >/dev/null
curl -fsS --max-time 10 http://relay-housekeeper:9064/metrics >/dev/null
curl -fsS --max-time 10 http://mev-boost:18550/eth/v1/builder/status >/dev/null
hash=$(curl -fsS --max-time 10 'http://relay-api:9062/relay/v1/data/bidtraces/proposer_payload_delivered?limit=20' | \
    jq -er '[.[] | select(.builder_pubkey == "0xa55c1285d84ba83a5ad26420cd5ad3091e49c55a813eee651cd467db38a8c8e63192f47955e9376f6b42f6d190571cb5")][0].block_hash')
block=$(rpc eth_getBlockByHash "[\"$hash\",false]" execution | jq -e .result)
number=$(jq -er .number <<< "$block")
canonical=$(rpc eth_getBlockByNumber "[\"$number\",false]" execution | jq -er .result.hash)
[[ "$hash" == "$canonical" ]]
echo "Relay-delivered builder block is canonical: number=$number hash=$hash"
