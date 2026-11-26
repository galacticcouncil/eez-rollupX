#!/usr/bin/env bash
set -euo pipefail
umask 022
peer=$(curl -fsS -H 'Content-Type: application/json' --data \
    '{"jsonrpc":"2.0","id":1,"method":"admin_nodeInfo","params":[]}' \
    http://execution:8545 | jq -er '.result.enode | capture("enode://(?<key>[0-9a-f]+)@").key')
address=$(getent ahostsv4 execution | awk 'NR == 1 {print $1}')
[[ -n "$address" ]]
printf 'enode://%s@%s:30303\n' "$peer" "$address" > /pbs/execution-peer.txt
peer=$(curl -fsS http://beacon:5052/eth/v1/node/identity | jq -er .data.peer_id)
printf '/dns4/beacon/tcp/9000/p2p/%s\n' "$peer" > /pbs/beacon-peer.txt
echo 'Recorded public execution and beacon peer identities.'
[[ "${EEZ_DEVNET_RELAY_PUBLIC_KEY:-}" =~ ^0x[0-9a-f]{96}$ ]]
sed "s/__RELAY_PUBLIC_KEY__/$EEZ_DEVNET_RELAY_PUBLIC_KEY/" /builder.template.toml > /pbs/builder.toml
printf 'http://%s@relay-api:9062\n' "$EEZ_DEVNET_RELAY_PUBLIC_KEY" > /pbs/relay-url.txt
curl -fsS http://beacon:5052/eth/v1/beacon/genesis | jq -er .data.genesis_time > /pbs/genesis-time.txt
