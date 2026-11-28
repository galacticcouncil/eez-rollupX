#!/usr/bin/env bash
set -euo pipefail
export PGPASSWORD="$(cat /run/secrets/relay-password)"
export PGCONNECT_TIMEOUT=3
deadline=$((SECONDS + 300))
while (( SECONDS < deadline )); do
    if psql -X -v ON_ERROR_STOP=1 -h postgres -U eez_lark_relay -d eez_lark_relay \
          -tAc 'SELECT 1' >/dev/null 2>&1 &&
       timeout 3 bash -c 'exec 3<>/dev/tcp/redis/6379; printf "*1\r\n\$4\r\nPING\r\n" >&3; read -r line <&3; [[ "$line" == +PONG* ]]'; then
        unset PGPASSWORD
        echo 'LARK_PBS_DATABASES_READY'
        exit 0
    fi
    sleep 2
done
echo 'Dedicated relay database/Redis readiness timed out.' >&2
exit 1
