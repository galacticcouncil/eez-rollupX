#!/usr/bin/env bash
set -euo pipefail
source /rpc.sh
check_l1
wait_builder
hash="$(jq -er .hash /input.json)"
receipt="$(rpc eth_getTransactionReceipt "[\"$hash\"]" | jq -e .result)"
number="$(jq -er .blockNumber <<< "$receipt")"
block="$(rpc eth_getBlockByNumber "[\"$number\",false]" | jq -e .result)"
jq -e --slurpfile expected /input.json '.status == "0x1" and .blockHash == $expected[0].block_hash' \
    <<< "$receipt" >/dev/null
[[ "$(jq -er .hash <<< "$block")" == "$(jq -er .block_hash /input.json)" ]]
builder="$(jq -er .builder_address /input.json)"
public_key="$(jq -er .builder_public_key /input.json)"
# Verify the retained canary and a canonical delivery from its builder identity.
# An idle builder need not emit empty bids; probe-pbs submits explicit private work.
delivered="$(curl -fsS --max-time 10 \
    'http://relay-api:9062/relay/v1/data/bidtraces/proposer_payload_delivered?limit=100' |
    jq -er --arg key "$public_key" '[.[] | select(.builder_pubkey == $key)][0].block_hash')"
delivery="$(rpc eth_getBlockByHash "[\"$delivered\",false]" | jq -e .result)"
jq -e --arg builder "$builder" '(.miner | ascii_downcase) == ($builder | ascii_downcase)' \
    <<< "$delivery" >/dev/null
height="$(jq -er .number <<< "$delivery")"
[[ "$(rpc eth_getBlockByNumber "[\"$height\",false]" | jq -er .result.hash)" == "$delivered" ]]
echo "LARK_PBS_READY $(jq -nc --arg hash "$hash" --arg block_hash "$(jq -r .hash <<< "$block")" \
    --arg delivered_block_hash "$delivered" --arg delivered_block_number "$height" \
    '{schema:1,chain_id:686868,hash:$hash,block_hash:$block_hash,delivered_block_hash:$delivered_block_hash,
      delivered_block_number:$delivered_block_number}')"
