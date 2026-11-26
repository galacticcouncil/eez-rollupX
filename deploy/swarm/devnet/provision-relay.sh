#!/usr/bin/env bash
# One-shot Swarm task with provisioning-only administrative credentials.
set -euo pipefail
export PGPASSWORD="$(< /run/secrets/admin-password)"
export RELAY_PASSWORD="$(< /run/secrets/relay-password)"
psql -X -v ON_ERROR_STOP=1 -h platform_postgres -U platform_admin -d postgres <<'SQL'
\getenv relay_password RELAY_PASSWORD
CREATE ROLE eez_devnet_relay LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'relay_password';
CREATE DATABASE eez_devnet_relay OWNER eez_devnet_relay;
REVOKE ALL ON DATABASE eez_devnet_relay FROM PUBLIC;
SQL
echo 'Created dedicated EEZ devnet relay role and database.'
