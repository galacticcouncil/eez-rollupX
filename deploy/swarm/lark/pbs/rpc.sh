#!/usr/bin/env bash
# Shared read-only checks. Mutating RPCs are explicit in the individual jobs.
set -euo pipefail
rpc() {
    local method=$1 params=$2 host=${3:-execution} port=${4:-8545}
    curl -fsS --max-time 10 -H 'Content-Type: application/json' \
        --data "$(jq -nc --arg method "$method" --argjson params "$params" \
          '{jsonrpc:"2.0",id:1,method:$method,params:$params}')" "http://$host:$port"
}
check_l1() {
    test -f /public/prepared
    (cd /public && sha256sum -c genesis.sha256 >/dev/null)
    [[ "$(rpc eth_chainId '[]' | jq -er .result)" == 0xa7b14 ]]
    [[ "$(rpc eth_getBlockByNumber '["0x0",false]' | jq -er .result.hash)" == \
       "$(jq -er .genesis_hash /public/prepared.json)" ]]
}
wait_builder() {
    local deadline=$((SECONDS + 1800)) head builder_head
    while (( SECONDS < deadline )); do
        head="$(rpc eth_blockNumber '[]' | jq -er .result)" || { sleep 2; continue; }
        builder_head="$(rpc eth_blockNumber '[]' builder | jq -er .result)" || { sleep 2; continue; }
        if [[ "$head" == "$builder_head" ]] &&
           [[ "$(rpc eth_chainId '[]' builder | jq -er .result)" == 0xa7b14 ]] &&
           curl -fsS --max-time 5 http://builder-beacon:5052/eth/v1/node/syncing |
             jq -e '.data.is_syncing == false and .data.is_optimistic == false' >/dev/null &&
           curl -fsS --max-time 5 http://relay-housekeeper:9064/metrics >/dev/null &&
           curl -fsS --max-time 5 http://mev-boost:18550/eth/v1/builder/status >/dev/null &&
           curl -fsS --max-time 5 http://relay-api:9062/relay/v1/builder/validators |
             jq -e 'type == "array" and length > 0' >/dev/null; then
            return
        fi
        sleep 2
    done
    echo 'Builder/relay/validator registration did not become ready.' >&2
    return 1
}
verify_canary() {
    local hash receipt number block canonical trace builder
    hash="$(jq -er .hash /input.json)" || return 1
    builder="$(jq -er .builder_address /input.json)" || return 1
    receipt="$(rpc eth_getTransactionReceipt "[\"$hash\"]" | jq -e .result)" || return 1
    jq -e --arg hash "$hash" --arg sender "$(jq -r .sender /input.json)" --arg builder "$builder" \
      '.status == "0x1" and .transactionHash == $hash and
       (.from | ascii_downcase) == ($sender | ascii_downcase) and
       (.to | ascii_downcase) == ($builder | ascii_downcase)' <<< "$receipt" >/dev/null || return 1
    number="$(jq -er .blockNumber <<< "$receipt")" || return 1
    block="$(rpc eth_getBlockByNumber "[\"$number\",false]" | jq -e .result)" || return 1
    canonical="$(jq -er .hash <<< "$block")" || return 1
    [[ "$canonical" == "$(jq -er .blockHash <<< "$receipt")" ]] || return 1
    # A local EL fallback pays the proposer directly. The builder uses its own coinbase.
    jq -e --arg builder "$builder" '(.miner | ascii_downcase) == ($builder | ascii_downcase)' \
        <<< "$block" >/dev/null || return 1
    trace="$(curl -fsS --max-time 10 \
      'http://relay-api:9062/relay/v1/data/bidtraces/proposer_payload_delivered?limit=100' |
      jq -ce --arg hash "$canonical" '[.[] | select(.block_hash == $hash)] |
        if length > 0 then .[0] else error("no canonical relay delivery") end')" || return 1
    jq -e '.builder_pubkey | test("^0x[0-9a-fA-F]{96}$")' <<< "$trace" >/dev/null || return 1
    jq -nc --arg hash "$hash" --arg block_hash "$canonical" --arg block_number "$number" \
        --arg builder_address "$builder" --arg builder_public_key "$(jq -r .builder_pubkey <<< "$trace")" \
        '{schema:1,chain_id:686868,hash:$hash,block_hash:$block_hash,block_number:$block_number,
          builder_address:$builder_address,builder_public_key:$builder_public_key}'
}
