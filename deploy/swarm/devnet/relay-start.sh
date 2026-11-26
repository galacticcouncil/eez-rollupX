#!/bin/sh
set -eu
# Read credentials only inside the task, never from service args or public config.
password=$(cat /run/secrets/relay-password)
export POSTGRES_DSN="postgresql://eez_devnet_relay:${password}@postgres:5432/eez_devnet_relay?sslmode=disable"
unset password
export GENESIS_VALIDATORS_ROOT=$(cat /genesis/metadata/genesis_validators_root.txt)
for fork in GENESIS ALTAIR BELLATRIX CAPELLA DENEB ELECTRA FULU; do
    value=$(awk -v name="${fork}_FORK_VERSION:" '$1 == name {print $2}' /genesis/metadata/config.yaml)
    test -n "$value"
    export "${fork}_FORK_VERSION=$value"
done
if [ "$1" = api ]; then
    # Housekeeper metrics opens after its schema migration and beacon readiness.
    ready=false
    for attempt in $(seq 1 120); do
        if wget -q -T 2 -O /dev/null http://relay-housekeeper:9064/metrics; then
            ready=true
            break
        fi
        sleep 1
    done
    "$ready" || { echo 'Housekeeper migration/readiness gate timed out'; exit 1; }
    export SECRET_KEY="0x$(cat /run/secrets/relay-signing-key)"
fi
exec /app/mev-boost-relay "$@"
