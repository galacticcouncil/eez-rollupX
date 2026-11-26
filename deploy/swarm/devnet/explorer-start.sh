#!/bin/sh
set -eu
test -f /out/deployment-complete
sha256sum -c /out/deployment.sha256
case "$EXPLORER_CHAIN" in
    l1) database=eez_l1_explorer ;;
    l2) database=eez_l2_explorer ;;
    *) echo 'Unknown explorer chain.' >&2; exit 1 ;;
esac
password=$(cat /run/secrets/db-password)
export DATABASE_URL="postgresql://$database:$password@postgres:5432/$database"
unset password
export SECRET_KEY_BASE="$(cat /run/secrets/web-secret)"
bin/blockscout eval 'Elixir.Explorer.ReleaseTasks.create_and_migrate()'
exec bin/blockscout start
