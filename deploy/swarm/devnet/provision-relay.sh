#!/usr/bin/env bash
# Official PostgreSQL entrypoint runs this once, on an empty devnet data volume.
set -euo pipefail
export RELAY_PASSWORD="$(< /run/secrets/relay-password)"
psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
\getenv relay_password RELAY_PASSWORD
CREATE ROLE eez_devnet_relay LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'relay_password';
CREATE DATABASE eez_devnet_relay OWNER eez_devnet_relay;
REVOKE ALL ON DATABASE eez_devnet_relay FROM PUBLIC;
SQL
unset RELAY_PASSWORD
echo 'Created dedicated EEZ devnet relay role and database.'
