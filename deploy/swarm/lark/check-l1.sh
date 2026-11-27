#!/usr/bin/env bash
# Finite overlay probe: bind execution/consensus to the prepared genesis.
set -euo pipefail
test -f /public/prepared
(cd /public && sha256sum -c genesis.sha256 >/dev/null)
rpc() {
    curl -fsS --max-time 10 -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" http://execution:8545
}
deadline=$((SECONDS + 3600))
while (( SECONDS < deadline )); do
    chain="$(rpc eth_chainId '[]' | jq -er .result)" || { sleep 12; continue; }
    [[ "$chain" == "$(printf '0x%x' 686868)" ]] || { echo 'Wrong Lark L1 chain ID.' >&2; exit 1; }
    genesis="$(rpc eth_getBlockByNumber '["0x0",false]' | jq -er .result.hash)" || { sleep 12; continue; }
    [[ "$genesis" == "$(jq -er .genesis_hash /public/prepared.json)" ]] || {
        echo 'Execution genesis does not match the prepared Lark chain.' >&2; exit 1;
    }
    consensus="$(curl -fsS --max-time 10 http://beacon:5052/eth/v1/beacon/genesis)" || { sleep 12; continue; }
    jq -e --slurpfile prepared /public/prepared.json \
        '.data.genesis_validators_root == $prepared[0].genesis_validators_root and
         (.data.genesis_time | tonumber) == $prepared[0].genesis_time' <<< "$consensus" >/dev/null
    first="$(rpc eth_blockNumber '[]' | jq -er .result)" || { sleep 12; continue; }
    sleep 24
    second="$(rpc eth_blockNumber '[]' | jq -er .result)" || { sleep 12; continue; }
    (( second > first )) || { sleep 12; continue; }
    curl -fsS --max-time 10 http://beacon:5052/eth/v1/node/syncing |
        jq -e '.data.is_optimistic == false' >/dev/null || { sleep 12; continue; }
    finalized="$(rpc eth_getBlockByNumber '["finalized",false]' | jq -er '.result.number // "0x0"')" || {
        sleep 12; continue;
    }
    if (( finalized > 0 )); then
        echo "LARK_L1_READY chain=686868 head=$second finalized=$finalized"
        exit 0
    fi
    sleep 12
done
echo 'Lark L1 readiness deadline expired; inspect the retained task.' >&2
exit 1
