#!/usr/bin/env bash
set -euo pipefail
source /rpc.sh
check_l1
[[ -z "$(find /pbs -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
    echo 'PBS bindings exist; inspect the original submission before recovery.' >&2; exit 1;
}
touch /pbs/bindings-started
key="$(rpc admin_nodeInfo '[]' | jq -er '.result.enode | capture("enode://(?<key>[0-9a-f]+)@").key')"
[[ "$key" =~ ^[0-9a-f]{128}$ ]]
address="$(getent ahostsv4 execution | awk 'NR == 1 {print $1}')"
[[ -n "$address" ]]
execution_peer="enode://$key@$address:30303"
peer="$(curl -fsS --max-time 10 http://beacon:5052/eth/v1/node/identity | jq -er .data.peer_id)"
[[ "$peer" =~ ^[a-zA-Z0-9]+$ ]]
beacon_peer="/dns4/beacon/tcp/9000/p2p/$peer"
relay="$(jq -er .relay_public_key /input.json)"
[[ "$relay" =~ ^0x[0-9a-f]{96}$ ]]
timestamp="$(jq -er .genesis_time /public/prepared.json)"
fork="$(awk '$1 == "GENESIS_FORK_VERSION:" {print $2}' /public/metadata/config.yaml)"
[[ "$fork" =~ ^0x[0-9a-fA-F]{8}$ ]]
printf '%s\n' "$execution_peer" > /pbs/execution-peer.txt
printf '%s\n' "$beacon_peer" > /pbs/beacon-peer.txt
printf 'http://%s@relay-api:9062\n' "$relay" > /pbs/relay-url.txt
printf '%s\n' "$timestamp" > /pbs/genesis-time.txt
jq -nc --arg execution_peer "$execution_peer" --arg beacon_peer "$beacon_peer" \
  --arg genesis_fork "$fork" --argjson genesis_time "$timestamp" \
  '{schema:1,execution_peer:$execution_peer,beacon_peer:$beacon_peer,
    genesis_fork:$genesis_fork,genesis_time:$genesis_time}' > /pbs/bindings.json
echo "LARK_PBS_BINDINGS $(cat /pbs/bindings.json)"
