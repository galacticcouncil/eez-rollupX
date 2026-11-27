#!/usr/bin/env bash
# One-shot private-network preparation. A partial attempt requires inspection.
set -euo pipefail
umask 077
trap 'echo "Lark preparation failed; inspect its private validator volume before recovery." >&2' ERR
[[ -z "$(find /public -mindepth 1 -maxdepth 1 -print -quit)" &&
   -z "$(find /validators -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
    echo 'Lark state exists; refusing to regenerate genesis or validator keys.' >&2
    exit 1
}
mkdir /public/preparation-started /validators/preparation
mnemonic="$(cat /run/secrets/validator-mnemonic)"
[[ "$mnemonic" =~ ^([a-z]+\ ){23}[a-z]+$ ]]
# The secret is read inside this task, never included in the saved service args.
eth2-val-tools keystores --source-mnemonic="$mnemonic" --source-min=0 --source-max=64 \
    --out-loc=/validators/generated > /validators/preparation/keystores.log 2>&1
cp -a /validators/generated/keys /validators/validators
cp -a /validators/generated/secrets /validators/secrets
export EL_AND_CL_MNEMONIC="$mnemonic"
export CHAIN_ID=686868 NUMBER_OF_VALIDATORS=64
export EL_PREMINE_COUNT=1 EL_PREMINE_BALANCE=1000000ETH EL_PREMINE_ADDRS='{}'
export GENESIS_TIMESTAMP="$(date +%s)" GENESIS_DELAY=300
export SLOT_DURATION_IN_SECONDS=12 SLOT_DURATION_MS=12000 GENESIS_GASLIMIT=60000000
export BPO_1_EPOCH=0 BPO_1_MAX_BLOBS=15 BPO_1_TARGET_BLOBS=10
export BPO_1_BASE_FEE_UPDATE_FRACTION=8346193
/work/entrypoint.sh all > /validators/preparation/generator.log 2>&1
unset mnemonic EL_AND_CL_MNEMONIC
jq -e '.config.chainId == 686868' /data/metadata/genesis.json >/dev/null || {
    echo 'Generated L1 chain ID does not match Lark.' >&2; exit 1;
}
jq -e '.validators | length == 64' /data/parsed/parsedConsensusGenesis.json >/dev/null
treasury="$(jq -er '[.alloc | to_entries[] |
    select(.value.balance == "1000000000000000000000000" and .value.code == null)] |
    if length == 1 then .[0].key else error("expected one fresh treasury") end' /data/metadata/genesis.json)"
[[ "$treasury" =~ ^(0x)?[0-9a-fA-F]{40}$ ]]
treasury="0x${treasury#0x}"
# The generator includes mnemonics.yaml and private traces. Copy a public allowlist.
install -d -m 0755 /public/metadata
for file in genesis.json genesis.ssz config.yaml deposit_contract.txt \
    deposit_contract_block.txt deposit_contract_block_hash.txt \
    genesis_validators_root.txt bootstrap_nodes.txt; do
    install -m 0644 "/data/metadata/$file" "/public/metadata/$file"
done
jq -n --arg treasury "$treasury" \
    --arg genesis_sha256 "$(sha256sum /public/metadata/genesis.json | cut -d ' ' -f 1)" \
    --slurpfile cl /data/parsed/parsedConsensusGenesis.json \
    '{schema:1, l1_chain_id:686868, l2_chain_id:696969, validators:64,
      treasury:$treasury, genesis_sha256:$genesis_sha256,
      genesis_hash:$cl[0].latest_execution_payload_header.block_hash,
      genesis_time:($cl[0].genesis_time | tonumber),
      genesis_validators_root:$cl[0].genesis_validators_root}' > /public/prepared.json
chmod 0644 /public/prepared.json
(cd /public && sha256sum metadata/* prepared.json > genesis.sha256)
chmod 0644 /public/genesis.sha256
touch /public/prepared
echo "LARK_PREPARED $(jq -c . /public/prepared.json)"
