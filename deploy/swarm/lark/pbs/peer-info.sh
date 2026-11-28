#!/usr/bin/env bash
set -euo pipefail
source /rpc.sh
check_l1
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
    identity="$(curl -fsS --max-time 10 http://beacon:5052/eth/v1/node/identity)" || { sleep 2; continue; }
    if jq -e '.data.p2p_addresses | length > 0' <<< "$identity" >/dev/null; then
        result="$(jq -ce '{schema:1,beacon_enr:.data.enr,peer_id:.data.peer_id}' <<< "$identity")"
        echo "LARK_BEACON_PEER $result"
        exit 0
    fi
    sleep 2
done
echo 'Canonical beacon did not advertise its private peer address.' >&2
exit 1
