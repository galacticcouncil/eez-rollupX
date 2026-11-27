#!/usr/bin/env bash
# Create a fresh local network once: both genesis files, the contract addresses
# the deployer will create, and each signer's verification key, under /state.
# Runs in the deploy image (Foundry, jq, Python and the node's genesis tools).
set -euo pipefail

STATE=/state
LOCAL="$(cd "$(dirname "$0")" && pwd)"
: "${L1_CHAIN_ID:?}" "${L2_CHAIN_ID:?}" "${L1_BLOCK_TIME_MS:?}" "${L2_BLOCK_TIME_MS:?}"
: "${DEPLOYER_KEY:?}" "${ORACLE_KEY:?}" "${KEEPER_KEY:?}"
: "${SIGNER_1_KEY:?}" "${SIGNER_2_KEY:?}" "${SIGNER_3_KEY:?}"

if [[ -f "$STATE/network.env" ]]; then
    echo "init: network already exists; run 'scripts/local-network.sh reset' for a new one"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
address_of() { cast wallet address --private-key "$1"; }

L1_GENESIS_HASH="$(python3 "$LOCAL/render-genesis.py" \
    --fixture /fixture/genesis.json --out-dir "$work" \
    --l1-chain-id "$L1_CHAIN_ID" --l2-chain-id "$L2_CHAIN_ID" \
    --l1-block-ms "$L1_BLOCK_TIME_MS" --l2-block-ms "$L2_BLOCK_TIME_MS" \
    --oracle-updater "$(address_of "$ORACLE_KEY")" --pepl-keeper "$(address_of "$KEEPER_KEY")")"
L2_GENESIS_HASH="$(eez-genesis-block-hash "$work/l2-genesis.json")"
NETWORK_PROFILE="$(eez-genesis-block-hash "$work/l2-genesis.json" --network-profile "$work/l1-genesis.json")"

# A fresh deployer's CREATE addresses are known in advance. The Composer needs
# them at startup, before its own built-in L1 exists to deploy to. This nonce
# order is what setup-contracts.sh sends (deploy_protocol_dev + TestQuorum).
DEPLOYER_ADDRESS="$(address_of "$DEPLOYER_KEY")"
address_at() { cast compute-address --nonce "$1" "$DEPLOYER_ADDRESS" | awk '{print $NF}'; }
REGISTRY_IMPLEMENTATION="$(address_at 0)"
EEZ_REGISTRY_ADDRESS="$(address_at 1)"
ROLLUP_IMPLEMENTATION="$(address_at 3)"
EEZ_ROLLUP_MANAGER_ADDRESS="$(address_at 4)"
proof_system_nonces=(2 6 7)

# Same preimage as scripts/deploy.sh and NetworkProfile::verification_key.
vkey_tag="$(cast keccak EEZ_ROLLUPX_VERIFICATION_KEY_V1)"
signer_keys=("$SIGNER_1_KEY" "$SIGNER_2_KEY" "$SIGNER_3_KEY")
for index in 0 1 2; do
    number=$((index + 1))
    signer="$(address_of "${signer_keys[$index]}")"
    system="$(address_at "${proof_system_nonces[$index]}")"
    vkey="$(cast keccak "$(cast abi-encode 'f(bytes32,bytes32,address,address,address)' \
        "$vkey_tag" "$NETWORK_PROFILE" "$EEZ_REGISTRY_ADDRESS" "$system" "$signer")")"
    printf 'SIGNER_ADDRESS=%s\nSIGNER_PROOF_SYSTEM=%s\nSIGNER_VKEY=%s\n' \
        "$signer" "$system" "$vkey" > "$work/signer-$number.env"
    printf 'SIGNER_%s_ADDRESS=%s\nSIGNER_%s_PROOF_SYSTEM=%s\nSIGNER_%s_VKEY=%s\n' \
        "$number" "$signer" "$number" "$system" "$number" "$vkey" >> "$work/signers.env"
done
# shellcheck disable=SC1091
source "$work/signer-1.env"

# Addresses and hashes only: the Composer sources this file, so no keys here.
cat > "$work/network.env" <<EOF
L1_GENESIS_HASH=$L1_GENESIS_HASH
L2_GENESIS_HASH=$L2_GENESIS_HASH
NETWORK_PROFILE=$NETWORK_PROFILE
DEPLOYER_ADDRESS=$DEPLOYER_ADDRESS
REGISTRY_IMPLEMENTATION=$REGISTRY_IMPLEMENTATION
ROLLUP_IMPLEMENTATION=$ROLLUP_IMPLEMENTATION
EEZ_REGISTRY_ADDRESS=$EEZ_REGISTRY_ADDRESS
EEZ_ROLLUP_MANAGER_ADDRESS=$EEZ_ROLLUP_MANAGER_ADDRESS
EEZ_ROLLUP_ID=1
EEZ_ECDSA_PROOF_SYSTEM_ADDRESS=$SIGNER_PROOF_SYSTEM
EEZ_ATTESTER_ADDRESS=$SIGNER_ADDRESS
EOF
cat "$work/signers.env" >> "$work/network.env"

# network.env goes last: its presence marks a complete initialization.
chmod 0644 "$work"/*
mv "$work"/l1-genesis.json "$work"/l2-genesis.json "$work"/signer-*.env "$STATE/"
mv "$work/network.env" "$STATE/network.env"
echo "init: L1 genesis $L1_GENESIS_HASH, L2 genesis $L2_GENESIS_HASH"
echo "init: registry $EEZ_REGISTRY_ADDRESS, rollup manager $EEZ_ROLLUP_MANAGER_ADDRESS"
