#!/usr/bin/env bash
set -euo pipefail
source /rpc.sh
check_l1
treasury="$(jq -er .treasury /public/prepared.json)"
nonce="$(rpc eth_getTransactionCount "[\"$treasury\",\"pending\"]" | jq -er .result)"
[[ "$nonce" == "$(rpc eth_getTransactionCount "[\"$treasury\",\"latest\"]" | jq -er .result)" ]] || {
    echo 'Treasury has unsettled transactions; refusing concurrent nonce use.' >&2; exit 1;
}
balance="$(rpc eth_getBalance "[\"$treasury\",\"latest\"]" | jq -er .result)"
block="$(rpc eth_getBlockByNumber '["latest",false]' | jq -e .result)"
echo "LARK_PBS_SNAPSHOT $(jq -nc --arg treasury "$treasury" --arg nonce "$nonce" \
  --arg balance "$balance" --arg base_fee "$(jq -er .baseFeePerGas <<< "$block")" \
  '{schema:1,treasury:$treasury,nonce:$nonce,balance:$balance,base_fee:$base_fee}')"
