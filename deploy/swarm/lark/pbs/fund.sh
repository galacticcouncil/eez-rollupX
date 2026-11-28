#!/usr/bin/env bash
# At most one broadcast of the already-signed, recorded transaction.
set -euo pipefail
source /rpc.sh
check_l1
hash="$(jq -er .hash /input.json)"
sender="$(jq -er .sender /input.json)"
receipt="$(rpc eth_getTransactionReceipt "[\"$hash\"]" | jq -c .result)"
known="$(rpc eth_getTransactionByHash "[\"$hash\"]" | jq -c .result)"
if [[ "$receipt" == null && "$known" == null ]]; then
    [[ "$(rpc eth_getTransactionCount "[\"$sender\",\"pending\"]" | jq -er .result)" == \
       "$(jq -er .nonce /input.json)" ]]
    raw="$(jq -er .raw /input.json)"
    # A transport failure can still have submitted it; only read after this call.
    rpc eth_sendRawTransaction "[\"$raw\"]" >/dev/null || true
fi
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
    receipt="$(rpc eth_getTransactionReceipt "[\"$hash\"]" | jq -c .result)"
    if [[ "$receipt" != null ]]; then
        tx="$(rpc eth_getTransactionByHash "[\"$hash\"]" | jq -e .result)"
        jq -e --slurpfile expected /input.json \
          '(.from | ascii_downcase) == ($expected[0].sender | ascii_downcase) and
           (.to | ascii_downcase) == ($expected[0].builder_address | ascii_downcase) and
           .hash == $expected[0].hash and .nonce == $expected[0].nonce and .value == $expected[0].value' \
          <<< "$tx" >/dev/null
        jq -e '.status == "0x1"' <<< "$receipt" >/dev/null
        number="$(jq -er .blockNumber <<< "$receipt")"
        canonical="$(rpc eth_getBlockByNumber "[\"$number\",false]" | jq -er .result.hash)"
        [[ "$canonical" == "$(jq -er .blockHash <<< "$receipt")" ]]
        echo "LARK_PBS_FUNDED $(jq -nc --arg hash "$hash" --arg block_hash "$canonical" \
          --arg block_number "$number" '{schema:1,hash:$hash,block_hash:$block_hash,block_number:$block_number}')"
        exit 0
    fi
    sleep 2
done
echo 'Funding receipt is inconclusive; retain the signed transaction and inspect before retry.' >&2
exit 1
