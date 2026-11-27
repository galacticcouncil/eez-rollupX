#!/usr/bin/env bash
# Runs once as a Swarm task. Never regenerate an existing chain or signing DB.
set -euo pipefail
umask 077
[[ ! -e /data/started ]] || { echo 'Already prepared; preserve existing genesis.'; exit 1; }
[[ -z "$(ls -A /data)" && -z "$(ls -A /validators)" ]] || {
    echo 'Partial preparation exists; inspect private volume logs before recovery.'; exit 1;
}
# Public development fixture. These validators must never join another network.
mnemonic='test test test test test test test test test test test junk'
export EL_AND_CL_MNEMONIC="$mnemonic"
export CHAIN_ID=414141 NUMBER_OF_VALIDATORS=64 EL_PREMINE_COUNT=0
export EL_PREMINE_ADDRS='{"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266":{"balance":"1000000ETH"}}'
export GENESIS_TIMESTAMP="$(date +%s)" GENESIS_DELAY=120
export SLOT_DURATION_IN_SECONDS=12 SLOT_DURATION_MS=12000
export GENESIS_GASLIMIT=60000000
export BPO_1_EPOCH=0 BPO_1_MAX_BLOBS=15 BPO_1_TARGET_BLOBS=10
export BPO_1_BASE_FEE_UPDATE_FRACTION=8346193
# Generator traces remain private, as future profiles may use real credentials.
/work/entrypoint.sh all > /data/generator.log 2>&1
eth2-val-tools keystores --source-mnemonic="$mnemonic" --source-min=0 --source-max=64 \
    --out-loc=/validators/generated > /data/keystores.log 2>&1
cp -a /validators/generated/keys /validators/validators
cp -a /validators/generated/secrets /validators/secrets
touch /data/started
echo 'Prepared private L1 genesis and 64 fixture validators.'
