#!/bin/sh
set -eu
export GENESIS_FORK_VERSION=$(awk '$1 == "GENESIS_FORK_VERSION:" {print $2}' /genesis/metadata/config.yaml)
export GENESIS_TIMESTAMP=$(cat /pbs/genesis-time.txt)
export RELAYS=$(cat /pbs/relay-url.txt)
export BOOST_LISTEN_ADDR=0.0.0.0:18550
export SLOT_SEC=12
exec /app/mev-boost
