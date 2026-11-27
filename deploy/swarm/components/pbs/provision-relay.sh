#!/usr/bin/env bash
# Official PostgreSQL entrypoint runs this once, on an empty stack data volume.
set -euo pipefail
[[ "${EEZ_RELAY_DATABASE:-}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || {
    echo 'Invalid relay database identifier.' >&2; exit 2;
}
export EEZ_RELAY_DATABASE
export RELAY_PASSWORD="$(< /run/secrets/relay-password)"
psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
\getenv relay_password RELAY_PASSWORD
\getenv relay_database EEZ_RELAY_DATABASE
CREATE ROLE :"relay_database" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'relay_password';
CREATE DATABASE :"relay_database" OWNER :"relay_database";
REVOKE ALL ON DATABASE :"relay_database" FROM PUBLIC;
SQL
unset RELAY_PASSWORD
echo 'Created dedicated relay role and database.'
