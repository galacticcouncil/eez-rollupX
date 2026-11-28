#!/usr/bin/env bash
# Public chain/peer state only; useful when a bounded readiness wait stalls.
set -euo pipefail
source /rpc.sh
check_l1
for host in execution builder; do
    echo "$host head: $(rpc eth_blockNumber '[]' "$host" | jq -c '{result,error}')"
    echo "$host peers: $(rpc admin_peers '[]' "$host" | jq -c '{result,error}')"
done
for host in beacon builder-beacon; do
    echo "$host DNS: $(getent ahostsv4 "$host")"
    if timeout 5 bash -c 'exec 3<>/dev/tcp/"$1"/9000' _ "$host"; then
        echo "$host TCP 9000: reachable"
    else
        echo "$host TCP 9000: unreachable"
    fi
    for path in identity syncing peer_count peers; do
        echo "$host $path: $(curl -fsS --max-time 10 "http://$host:5052/eth/v1/node/$path" | jq -c .)"
    done
done
