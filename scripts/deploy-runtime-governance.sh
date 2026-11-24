#!/usr/bin/env bash
# Opt-in follow-on to deploy.sh. Public configuration only; use Foundry's
# keystore/hardware signer options. No keys are read, accepted, or printed here.
set -euo pipefail
if (( $# < 3 )); then
    echo "usage: bash scripts/deploy-runtime-governance.sh CONFIG.json GENESIS.json PINS-OUT.json [--account NAME --sender ADDRESS] [--broadcast]" >&2
    exit 2
fi
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$(realpath "$1")"
GENESIS="$(realpath "$2")"
PINS_OUT="$3"
shift 3
: "${EEZ_L1_RPC_URL:?set EEZ_L1_RPC_URL}"
[[ ! -e "$PINS_OUT" ]] || { echo "refusing to overwrite $PINS_OUT" >&2; exit 1; }
[[ -d "$(dirname "$PINS_OUT")" ]] || { echo "pins output directory must already exist" >&2; exit 1; }
jq -e '
    .genesis_release as $genesis | (.supported_releases // [$genesis]) as $supported |
    $genesis.runtimeVersion == 0 and ($supported | index($genesis)) != null
    and (.max_entries // 100) > 0 and (.max_entries // 100) <= 100000
' "$CONFIG" >/dev/null || { echo "invalid genesis allowlist or entry bound" >&2; exit 1; }
broadcast=false
for argument in "$@"; do
    case "$argument" in
        --broadcast) broadcast=true ;;
        --private-key|--private-key=*|--mnemonic*|--rpc-url*|--sig*|--resume|--skip-simulation)
            echo "unsupported option: use an external Foundry signer; keep the pinned RPC, signature, and simulation" >&2
            exit 2 ;;
    esac
done
expected_chain="$(jq -er '.l1_chain_id' "$CONFIG")"
actual_chain="$(cast chain-id --rpc-url "$EEZ_L1_RPC_URL")"
[[ "$expected_chain" == "$actual_chain" ]] || { echo "L1 chain id mismatch" >&2; exit 1; }
# Rust uses the same genesis/header construction as the L2 node. Run after
# deploy.sh has finalized genesis.json's timestamp and fork configuration.
identity="$(cd "$REPO" && cargo +1.96.0 run --quiet --locked -p hydration-governance --example genesis_identity -- "$GENESIS")"
manager="$(jq -er '.manager' "$CONFIG")"
registry="$(jq -er '.eez_registry' "$CONFIG")"
rollup_id="$(jq -er '.rollup_id' "$CONFIG")"
actual_registry="$(cast call "$manager" 'EEZContract()(address)' --rpc-url "$EEZ_L1_RPC_URL")"
actual_id="$(cast call "$manager" 'rollupId()(uint64)' --rpc-url "$EEZ_L1_RPC_URL" | awk '{print $1}')"
[[ "${registry,,}" == "${actual_registry,,}" && "$rollup_id" == "$actual_id" ]] || {
    echo "manager registry/rollup pin mismatch" >&2; exit 1;
}
block_seconds="$(jq -er '.l2_block_seconds' "$CONFIG")"
# Require the actual devnet cadence explicitly, in its native config unit.
: "${EEZ_L2_BLOCK_TIME_MS:?set the actual devnet EEZ_L2_BLOCK_TIME_MS}"
[[ "$EEZ_L2_BLOCK_TIME_MS" =~ ^[0-9]+$ && "$block_seconds" =~ ^[1-9][0-9]*$ ]] || {
    echo "invalid L2 timing" >&2; exit 1;
}
(( EEZ_L2_BLOCK_TIME_MS % 1000 == 0 && EEZ_L2_BLOCK_TIME_MS / 1000 == block_seconds )) || {
    echo "whole-second L2 timing mismatch" >&2; exit 1;
}
tuple="$(jq -er --argjson identity "$identity" '
    def release: "(" + ([.runtimeVersion,.releaseHash,.nodeArtifactHash,.guestArtifactHash,.programVKey] | map(tostring) | join(",")) + ")";
    "(" + ([.manager,.authority,.source_domain,.min_delay,$identity.chain_id,$identity.genesis_hash,
        $identity.genesis_timestamp,.l2_block_seconds,.min_notice,.cancel_notice] | map(tostring) | join(","))
        + "," + (.genesis_release | release) + ")"
' "$CONFIG")"
if ! output="$(cd "$REPO/contracts" && forge script script/DeployRuntimeGovernance.s.sol:DeployRuntimeGovernance \
    --sig 'run((address,address,bytes32,uint64,uint256,bytes32,uint64,uint64,uint64,uint64,(uint32,bytes32,bytes32,bytes32,bytes32)))' \
    "$tuple" --rpc-url "$EEZ_L1_RPC_URL" "$@")"; then
    printf '%s\n' "$output" >&2
    echo "deployment failed; inspect broadcast receipts and current owner before retrying" >&2
    exit 1
fi
printf '%s\n' "$output"
if ! "$broadcast"; then
    echo "Simulation only. No pins written. Add --broadcast for an intentional devnet handoff."
    exit 0
fi
controller="$(sed -nE 's/.*UPGRADE_CONTROLLER=(0x[0-9a-fA-F]{40}).*/\1/p' <<< "$output" | tail -1)"
schedule="$(sed -nE 's/.*EXECUTION_SCHEDULE=(0x[0-9a-fA-F]{40}).*/\1/p' <<< "$output" | tail -1)"
[[ -n "$controller" && -n "$schedule" ]] || { echo "cannot identify deployment; inspect broadcast receipts before retrying" >&2; exit 1; }
owner="$(cast call "$manager" 'owner()(address)' --rpc-url "$EEZ_L1_RPC_URL")"
[[ "${owner,,}" == "${controller,,}" ]] || { echo "manager handoff incomplete" >&2; exit 1; }
schedule_code="$(cast code "$schedule" --rpc-url "$EEZ_L1_RPC_URL")"
controller_code="$(cast code "$controller" --rpc-url "$EEZ_L1_RPC_URL")"
[[ "$schedule_code" != "0x" && "$controller_code" != "0x" ]] || { echo "deployment code missing" >&2; exit 1; }
schedule_hash="$(cast keccak "$schedule_code")"
controller_hash="$(cast keccak "$controller_code")"
# The allowlist is local operator policy; never populate it from on-chain entries.
# noclobber also protects against a concurrent invocation claiming the same file.
set -o noclobber
jq --argjson identity "$identity" --arg schedule "$schedule" --arg controller "$controller" \
    --arg schedule_hash "$schedule_hash" --arg controller_hash "$controller_hash" '
    {l1_chain_id, schedule:$schedule, schedule_code_hash:$schedule_hash, controller:$controller,
     controller_code_hash:$controller_hash, eez_registry, rollup_id,
     l2_chain_id:($identity.chain_id | tostring), l2_genesis_hash:$identity.genesis_hash,
     l2_genesis_timestamp:$identity.genesis_timestamp, l2_block_seconds, max_entries:(.max_entries // 100),
     supported_releases:(.supported_releases // [.genesis_release])}
' "$CONFIG" > "$PINS_OUT"
echo "Wrote public reader pins to $PINS_OUT. Independently verify code/build hashes before use."
echo "No node execution path was enabled. Wait for L1 finality before inspecting the schedule."
