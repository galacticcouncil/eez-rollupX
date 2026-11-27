#!/usr/bin/env bash
# Deploy the protocol on the Composer's built-in L1 at the addresses init.sh
# computed, register signers 2 and 3, require two proofs per batch, and write
# /state/roster.env so the restarted Composer asks all three signers.
# Same transactions as deploy_protocol_dev and TestQuorum::register (eez-testkit).
set -euo pipefail

STATE=/state
RPC=http://127.0.0.1:18645
OUT=/repo/contracts/out
: "${L1_CHAIN_ID:?}" "${DEPLOYER_KEY:?}"
set -a
# shellcheck disable=SC1091
source "$STATE/network.env"
set +a

if [[ -f "$STATE/roster.env" ]]; then
    echo "contracts: already deployed"
    exit 0
fi
fail() { echo "contracts: $*" >&2; exit 1; }
lower() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

for _ in $(seq 60); do
    cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 2
done
[[ "$(cast chain-id --rpc-url "$RPC")" == "$L1_CHAIN_ID" ]] || fail "L1 RPC at $RPC is not chain $L1_CHAIN_ID"
[[ "$(cast block 0 --field hash --rpc-url "$RPC")" == "$L1_GENESIS_HASH" ]] \
    || fail "L1 block zero differs from the rendered genesis; reset the network"
[[ "$(cast nonce "$DEPLOYER_ADDRESS" --rpc-url "$RPC")" == 0 ]] \
    || fail "deployer already has transactions; reset the network"

forge build --root /repo/contracts

# Send one deployment and check it landed at the precomputed address.
create() {
    local artifact="$1" expected="$2" receipt
    shift 2
    receipt="$(cast send --json --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" \
        --create "$(jq -er .bytecode.object "$OUT/$artifact")" "$@")"
    [[ "$(jq -r .status <<< "$receipt")" == 0x1 ]] || fail "$artifact deployment reverted"
    [[ "$(lower "$(jq -r .contractAddress <<< "$receipt")")" == "$(lower "$expected")" ]] \
        || fail "$artifact deployed at an unexpected address"
    echo "contracts: $artifact at $expected"
}
call() {
    local receipt
    receipt="$(cast send --json --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" "$@")"
    [[ "$(jq -r .status <<< "$receipt")" == 0x1 ]] || fail "$2 reverted"
}

# Nonces 0-4: registry and rollup manager behind proxies, signer 1's verifier.
create EEZ.sol/EEZ.json "$REGISTRY_IMPLEMENTATION" "constructor(address)" "$DEPLOYER_ADDRESS"
create EEZProxy.sol/EEZProxy.json "$EEZ_REGISTRY_ADDRESS" \
    "constructor(address,address)" "$REGISTRY_IMPLEMENTATION" "$DEPLOYER_ADDRESS"
create ECDSAProofSystem.sol/ECDSAProofSystem.json "$SIGNER_1_PROOF_SYSTEM" \
    "constructor(address)" "$SIGNER_1_ADDRESS"
create Rollup.sol/Rollup.json "$ROLLUP_IMPLEMENTATION" "constructor(address)" "$EEZ_REGISTRY_ADDRESS"
initialize="$(cast calldata "initialize(address,uint256,address[],bytes32[])" \
    "$DEPLOYER_ADDRESS" 1 "[$SIGNER_1_PROOF_SYSTEM]" "[$SIGNER_1_VKEY]")"
create TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json "$EEZ_ROLLUP_MANAGER_ADDRESS" \
    "constructor(address,address,bytes)" "$ROLLUP_IMPLEMENTATION" "$DEPLOYER_ADDRESS" "$initialize"

# Nonce 5: register rollup 1 with the L2 genesis block as its first root.
call "$EEZ_REGISTRY_ADDRESS" "registerRollup(address,bytes32)" "$EEZ_ROLLUP_MANAGER_ADDRESS" "$L2_GENESIS_HASH"
[[ "$(cast call "$EEZ_REGISTRY_ADDRESS" "rollupCounter()(uint256)" --rpc-url "$RPC")" == "$EEZ_ROLLUP_ID" ]] \
    || fail "rollup was not registered as rollup $EEZ_ROLLUP_ID"

# Nonces 6-10: verifiers for signers 2 and 3, their registration, threshold 2.
create ECDSAProofSystem.sol/ECDSAProofSystem.json "$SIGNER_2_PROOF_SYSTEM" "constructor(address)" "$SIGNER_2_ADDRESS"
create ECDSAProofSystem.sol/ECDSAProofSystem.json "$SIGNER_3_PROOF_SYSTEM" "constructor(address)" "$SIGNER_3_ADDRESS"
call "$EEZ_ROLLUP_MANAGER_ADDRESS" "addProofSystem(address,bytes32)" "$SIGNER_2_PROOF_SYSTEM" "$SIGNER_2_VKEY"
call "$EEZ_ROLLUP_MANAGER_ADDRESS" "addProofSystem(address,bytes32)" "$SIGNER_3_PROOF_SYSTEM" "$SIGNER_3_VKEY"
call "$EEZ_ROLLUP_MANAGER_ADDRESS" "setThreshold(uint256)" 2
[[ "$(cast call "$EEZ_ROLLUP_MANAGER_ADDRESS" "threshold()(uint256)" --rpc-url "$RPC")" == 2 ]] \
    || fail "threshold is not 2"
echo "contracts: signers 1-3 registered, threshold 2"

# url=attester=verifier per member (docs/runbooks/attestation-quorum.md).
roster="http://signer-1:50061=$SIGNER_1_ADDRESS=$SIGNER_1_PROOF_SYSTEM"
roster+=",http://signer-2:50061=$SIGNER_2_ADDRESS=$SIGNER_2_PROOF_SYSTEM"
roster+=",http://signer-3:50061=$SIGNER_3_ADDRESS=$SIGNER_3_PROOF_SYSTEM"
printf 'EEZ_PROVERS=%s\n' "$roster" > "$STATE/roster.env.tmp"
mv "$STATE/roster.env.tmp" "$STATE/roster.env"
