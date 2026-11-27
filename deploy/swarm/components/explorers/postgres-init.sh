#!/usr/bin/env bash
# Runs once on the explorer stack's empty PostgreSQL volume.
set -euo pipefail
export L1_PASSWORD="$(< /run/secrets/l1-db-password)"
export L2_PASSWORD="$(< /run/secrets/l2-db-password)"
psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
\getenv l1_password L1_PASSWORD
\getenv l2_password L2_PASSWORD
CREATE ROLE eez_l1_explorer LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'l1_password';
CREATE ROLE eez_l2_explorer LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'l2_password';
CREATE DATABASE eez_l1_explorer OWNER eez_l1_explorer;
CREATE DATABASE eez_l2_explorer OWNER eez_l2_explorer;
REVOKE ALL ON DATABASE eez_l1_explorer FROM PUBLIC;
REVOKE ALL ON DATABASE eez_l2_explorer FROM PUBLIC;
SQL
unset L1_PASSWORD L2_PASSWORD
