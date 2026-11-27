#!/usr/bin/env bash
# Outside-in test of the local network. One L2 transaction bumps Hydration's
# counter precompile and pushes the new count to an L1 contract in the same
# flow (contracts/src/CounterRelay.sol). The batch must then settle on L1 with
# at least two of the three signers' proofs. It talks to the network only
# through the published RPC ports and reads addresses from /state/network.env.
set -euo pipefail

L1=http://127.0.0.1:18545
L2=http://127.0.0.1:18688
L2_FRONT=http://127.0.0.1:18998
TIMEOUT=300
OUT=/repo/contracts/out
COUNTER=0x0000000000000000000000000000000000000800
EEZL2=0x4B2760F84B83d6b3829E30A7573B0172B6d6402C
: "${L2_CHAIN_ID:?}" "${APP_DEPLOYER_KEY:?}" "${USER_KEY:?}"
set -a
# shellcheck disable=SC1091
source /state/network.env
set +a

step() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
lower() { tr '[:upper:]' '[:lower:]' <<< "$1"; }
# First field only: cast annotates large numbers, e.g. "1000 [1e3]".
number() { "$@" | awk 'NR == 1 {print $1}'; }
# Retry a command until its output equals the expected value.
wait_for() {
    local what="$1" expected="$2" got="" deadline=$((SECONDS + TIMEOUT))
    shift 2
    while ((SECONDS < deadline)); do
        got="$("$@" 2>/dev/null || true)"
        [[ "$got" == "$expected" ]] && return 0
        sleep 2
    done
    fail "$what: expected $expected, last saw '${got}'"
}
deploy() {
    local rpc="$1" artifact="$2"
    shift 2
    cast send --json --rpc-url "$rpc" --private-key "$APP_DEPLOYER_KEY" \
        --create "$(jq -er .bytecode.object "$OUT/$artifact")" "$@" \
        | jq -er 'select(.status == "0x1") | .contractAddress'
}

step "waiting for the L2 RPC and the L2 front"
wait_for "L2 chain id" "$L2_CHAIN_ID" cast chain-id --rpc-url "$L2"
wait_for "L2 front chain id" "$L2_CHAIN_ID" cast chain-id --rpc-url "$L2_FRONT"
forge build --root /repo/contracts

step "deploying Value on L1, its L2 proxy and CounterRelay on L2"
# Start at 0: every pushed count is at least 1, so L1 always reports a change.
value_l1="$(deploy "$L1" Value.sol/Value.json "constructor(uint256)" 0)"
proxy="$(cast call "$EEZL2" "computeCrossChainProxyAddress(address,uint64)(address)" "$value_l1" 0 --rpc-url "$L2")"
cast send --rpc-url "$L2" --private-key "$APP_DEPLOYER_KEY" "$EEZL2" \
    "createCrossChainProxy(address,uint64)" "$value_l1" 0 >/dev/null
relay="$(deploy "$L2" CounterRelay.sol/CounterRelay.json "constructor(address)" "$proxy")"
echo "    Value (L1) $value_l1, proxy (L2) $proxy, CounterRelay (L2) $relay"

# Let two Sync intervals pass so the Composer's next simulation sees the code.
ready_at=$(($(cast block-number --rpc-url "$L2") + 10))
while (($(cast block-number --rpc-url "$L2") < ready_at)); do sleep 1; done

before="$(number cast call "$COUNTER" "get()(uint256)" --rpc-url "$L2")"
expected=$((before + 1))
l1_from=$(($(cast block-number --rpc-url "$L1") + 1))

step "sending bumpAndRelay() through the L2 front (counter $before -> $expected)"
tx="$(cast send --async --rpc-url "$L2_FRONT" --private-key "$USER_KEY" --gas-limit 900000 \
    "$relay" "bumpAndRelay()")"
wait_for "L2 receipt status of $tx" 0x1 \
    sh -c "cast receipt --async --json '$tx' --rpc-url '$L2' | jq -r .status"
tx_block="$(cast receipt --json "$tx" --rpc-url "$L2" | jq -r .blockNumber | xargs cast to-dec)"

step "checking the L1 leg and the values returned into the L2 frame"
wait_for "L1 Value" "$expected" number cast call "$value_l1" "value()(uint256)" --rpc-url "$L1"
[[ "$(number cast call "$relay" "relayed()(uint256)" --rpc-url "$L2")" == 1 ]] || fail "relayed() is not 1"
[[ "$(number cast call "$relay" "lastCount()(uint256)" --rpc-url "$L2")" == "$expected" ]] || fail "lastCount() is not $expected"
[[ "$(cast call "$relay" "lastChanged()(bool)" --rpc-url "$L2")" == true ]] || fail "L1 answer was not decoded on L2"

step "waiting for L1 to settle L2 block $tx_block or later"
settled() {
    local root safe_hash safe_number
    root="$(cast call "$EEZ_REGISTRY_ADDRESS" "rollups(uint64)(address,bytes32,uint256)" \
        "$EEZ_ROLLUP_ID" --rpc-url "$L1" | sed -n 2p)"
    safe_hash="$(cast block safe --field hash --rpc-url "$L2")"
    safe_number="$(cast block safe --field number --rpc-url "$L2")"
    [[ "$root" == "$safe_hash" ]] && ((safe_number >= tx_block)) && echo "$safe_hash"
}
deadline=$((SECONDS + TIMEOUT))
until safe_hash="$(settled 2>/dev/null)"; do
    ((SECONDS < deadline)) || fail "L1 root never reached L2 block $tx_block"
    sleep 2
done
slot="$(cast storage "$COUNTER" 0 --block "$safe_hash" --rpc-url "$L2" | xargs cast to-dec)"
[[ "$slot" == "$expected" ]] || fail "settled L2 block holds counter $slot, expected $expected"

step "checking every L1 post since the transaction carries 2+ proofs from our signers"
[[ "$(number cast call "$EEZ_ROLLUP_MANAGER_ADDRESS" "threshold()(uint256)" --rpc-url "$L1")" == 2 ]] \
    || fail "rollup threshold is not 2"
selector="$(jq -er '.methodIdentifiers | to_entries[] | select(.key | startswith("postAndVerifyBatch(")) | .value' \
    "$OUT/EEZ.sol/EEZ.json")"
registered=" $(lower "$SIGNER_1_PROOF_SYSTEM") $(lower "$SIGNER_2_PROOF_SYSTEM") $(lower "$SIGNER_3_PROOF_SYSTEM") "
posts=0
l1_tip="$(cast block-number --rpc-url "$L1")"
for ((block = l1_from; block <= l1_tip; block++)); do
    for hash in $(cast block "$block" --full --json --rpc-url "$L1" | jq -r \
        --arg to "$(lower "$EEZ_REGISTRY_ADDRESS")" --arg selector "0x$selector" \
        '.transactions[] | select((.to // "" | ascii_downcase) == $to and (.input | startswith($selector))) | .hash'); do
        [[ "$(cast receipt --json "$hash" --rpc-url "$L1" | jq -r .status)" == 0x1 ]] || continue
        # Read proofSystems (field 5) and proofs (field 9) of the batch tuple.
        read -r proofs systems <<< "$(cast tx "$hash" input --rpc-url "$L1" | python3 -c '
import sys
data = bytes.fromhex(sys.stdin.read().strip()[2:])[4:]
word = lambda offset: int.from_bytes(data[offset:offset + 32], "big")
batch = word(0)
def array(field):
    start = batch + word(batch + 32 * field)
    return start + 32, word(start)
systems_at, systems = array(5)
_, proofs = array(9)
print(proofs, ",".join("0x" + data[systems_at + 32 * i + 12:systems_at + 32 * (i + 1)].hex()
                       for i in range(systems)))')"
        signers=()
        for system in ${systems//,/ }; do
            [[ "$registered" == *" $system "* ]] || fail "post $hash used unknown proof system $system"
            signers+=("$(cast call "$system" "signer()(address)" --rpc-url "$L1")")
        done
        count=$(printf '%s\n' "${signers[@]}" | sort -u | wc -l | tr -d ' ')
        ((proofs == ${#signers[@]} && count >= 2)) || fail "post $hash carried $count distinct signer(s)"
        echo "    L1 block $block: post $hash verified $proofs proofs from ${signers[*]}"
        posts=$((posts + 1))
    done
done
((posts > 0)) || fail "no successful post found on L1 since block $l1_from"

echo "PASS: Hydration counter $before -> $expected reached L1 and settled with 2 of 3 signers ($posts post(s))"
