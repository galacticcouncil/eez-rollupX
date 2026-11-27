#!/usr/bin/env bash
# Public private-network fixtures only. Broadcasts one tiny L1 bundle canary.
set -euo pipefail
[[ "$(cast chain-id --rpc-url http://execution:8545)" == 414141 ]]
ready=false
for attempt in {1..180}; do
    head=$(timeout 3 cast block-number --rpc-url http://execution:8545) || head=-1
    builder_head=$(timeout 3 cast block-number --rpc-url http://builder:8545) || builder_head=-2
    if (( head >= 0 && builder_head == head )) && timeout 3 bash -c ': >/dev/tcp/builder/8645' &&
        curl -fsS --max-time 3 http://relay-api:9062/relay/v1/builder/validators |
        jq -e 'type == "array" and length > 0' >/dev/null; then
        ready=true
        break
    fi
    sleep 2
done
"$ready" || { echo 'Builder did not become ready before canary submission'; exit 1; }
sender=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
key=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
nonce=$(cast nonce "$sender" --rpc-url http://execution:8545)
raw=$(cast mktx --rpc-url http://execution:8545 --private-key "$key" --nonce "$nonce" \
    --gas-limit 21000 --gas-price 2gwei --value 0.01ether 0xb9e79D19f651a941757b35830232E7EFC77E1c79)
hash=$(cast keccak "$raw")
head=$(cast block-number --rpc-url http://execution:8545)
target=$(printf '0x%x' "$((head + 2))")
params=$(printf '[{"txs":["%s"],"blockNumber":"%s"}]' "$raw" "$target")
cast rpc --rpc-url http://builder:8645 --raw eth_sendBundle "$params"
echo "Submitted bundle canary: tx=$hash target=$target"
for attempt in {1..30}; do
    receipt=$(timeout 3 cast receipt "$hash" --rpc-url http://execution:8545 --json 2>/dev/null) || receipt=''
    if [[ "$receipt" == *'"status":"0x1"'* || "$receipt" == *'"status": "0x1"'* ]]; then
        printf '%s\n' "$receipt"
        exit 0
    fi
    sleep 2
done
echo 'Bundle canary did not settle in its target block.' >&2
exit 1
