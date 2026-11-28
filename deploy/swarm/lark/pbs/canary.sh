#!/usr/bin/env bash
# A private bundle only: never send this transaction to the public L1 mempool.
set -euo pipefail
source /rpc.sh
check_l1
wait_builder
hash="$(jq -er .hash /input.json)"
receipt="$(rpc eth_getTransactionReceipt "[\"$hash\"]" | jq -c .result)"
if [[ "$receipt" != null ]]; then
    proof="$(verify_canary)"
    echo "LARK_PBS_CANARY $proof"
    exit 0
fi
sender="$(jq -er .sender /input.json)"
[[ "$(rpc eth_getTransactionCount "[\"$sender\",\"pending\"]" | jq -er .result)" == \
   "$(jq -er .nonce /input.json)" ]]
head="$(rpc eth_blockNumber '[]' | jq -er .result)"
[[ "$head" =~ ^0x[0-9a-f]{1,15}$ ]]
target="$(printf '0x%x' "$((head + 2))")"
params="$(jq -nc --arg raw "$(jq -er .raw /input.json)" --arg target "$target" \
    '[{txs:[$raw],blockNumber:$target}]')"
rpc eth_sendBundle "$params" builder 8645 | jq -e 'has("error") | not' >/dev/null
echo "LARK_PBS_BUNDLE hash=$hash target=$target"
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
    receipt="$(rpc eth_getTransactionReceipt "[\"$hash\"]" | jq -c .result)"
    if [[ "$receipt" != null ]]; then
        [[ "$(jq -er .blockNumber <<< "$receipt")" == "$target" ]]
        proof="$(verify_canary)"
        echo "LARK_PBS_CANARY $proof"
        exit 0
    fi
    sleep 2
done
echo 'The single-target bundle did not become canonical; inspect the retained attempt.' >&2
exit 1
