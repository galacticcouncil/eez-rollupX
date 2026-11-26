#!/usr/bin/env bash
# A state-changing test: public fixture account pays gas on local L2 only.
set -euo pipefail
test -f /out/deployment-complete
source /out/deployments.env
source /l2-fixtures.env
L1=http://execution:8545
L2=http://eez-node:18688
counter=0x0000000000000000000000000000000000000800
[[ "$(timeout 10 cast chain-id --rpc-url "$L1")" == 414141 ]]
ready=false
for ((attempt=0; attempt<90; attempt++)); do
    if block=$(timeout 5 cast block latest --rpc-url "$L2" --json 2>/dev/null); then
        timestamp=$(jq -er .timestamp <<< "$block")
        lag=$(($(date +%s) - timestamp))
        if ((lag >= -2 && lag <= 12)) &&
            curl -fsS --max-time 5 http://eez-beacon:5252/eth/v1/node/syncing |
            jq -e '.data.is_optimistic == false and .data.el_offline == false' >/dev/null; then
            ready=true
            break
        fi
    fi
    sleep 2
done
"$ready" || { echo 'L2 timestamp catch-up / L1 beacon readiness timed out.' >&2; exit 1; }
[[ "$(timeout 10 cast chain-id --rpc-url "$L2")" == 424242 ]]
before=$(timeout 10 cast call "$counter" 'get()(uint256)' --rpc-url "$L2" | awk '{print $1}')
[[ "$before" =~ ^[0-9]+$ && "$before" -lt 1000000 ]]
tx=$(timeout 20 cast send "$counter" 'increment()' --gas-limit 100000 \
    --private-key "$EEZ_L1_POSTER_KEY" --rpc-url "$L2" --async)
echo "Hydration counter canary submitted: $tx"
receipt=''
for ((attempt=0; attempt<60; attempt++)); do
    if receipt=$(timeout 5 cast receipt "$tx" --rpc-url "$L2" --json 2>/dev/null); then
        [[ "$(jq -r .status <<< "$receipt")" == 0x1 ]]
        break
    fi
    sleep 2
done
height=$(jq -er .blockNumber <<< "$receipt")
hash=$(jq -er .blockHash <<< "$receipt")
after=$(timeout 10 cast call "$counter" 'get()(uint256)' --block "$height" --rpc-url "$L2" | awk '{print $1}')
[[ "$after" == "$((before + 1))" ]]
echo "Counter $before -> $after in L2 block $height ($hash). Waiting for canonical L1 commitment."
for ((attempt=0; attempt<90; attempt++)); do
    record=$(timeout 10 cast call "$EEZ_REGISTRY_ADDRESS" 'rollups(uint64)(address,bytes32,uint256)' \
        "$EEZ_ROLLUP_ID" --rpc-url "$L1")
    root=$(sed -n '2p' <<< "$record")
    if [[ "$root" != "$EEZ_INITIAL_BLOCK_HASH" ]]; then
        if block=$(timeout 10 cast block "$root" --rpc-url "$L2" --json 2>/dev/null); then
            settled=$(jq -er .number <<< "$block")
            if ((settled >= height)); then
                canonical=$(timeout 10 cast block "$settled" --rpc-url "$L2" --json | jq -er .hash)
                recheck=$(timeout 10 cast call "$EEZ_REGISTRY_ADDRESS" 'rollups(uint64)(address,bytes32,uint256)' \
                    "$EEZ_ROLLUP_ID" --rpc-url "$L1" | sed -n '2p')
                [[ "$canonical" == "$root" && "$recheck" == "$root" ]]
                # Recheck the actual receipt block after canonical commitment advancement.
                [[ "$(timeout 10 cast block "$height" --rpc-url "$L2" --json | jq -er .hash)" == "$hash" ]]
                [[ "$(timeout 10 cast call "$counter" 'get()(uint256)' --block "$settled" --rpc-url "$L2" | awk '{print $1}')" == "$after" ]]
                echo "PASS: Hydration counter execution and canonical settlement through L2 block $settled ($root)."
                exit 0
            fi
        fi
    fi
    sleep 12
done
echo 'Counter executed locally but canonical L1 settlement was not established within the budget.' >&2
exit 1
