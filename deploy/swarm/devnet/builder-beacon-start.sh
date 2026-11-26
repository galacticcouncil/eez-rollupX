#!/usr/bin/env bash
set -euo pipefail
exec lighthouse bn --testnet-dir=/genesis/metadata --datadir=/beacon \
    --execution-endpoint=http://builder:8551 --execution-jwt=/run/secrets/engine-jwt \
    --http --http-address=0.0.0.0 --enable-private-discovery \
    --boot-nodes="$(< /pbs/beacon-peer.txt)" \
    --libp2p-addresses="$(< /pbs/beacon-peer.txt)" \
    --checkpoint-sync-url=http://beacon:5052 --supernode --always-prepare-payload \
    --suggested-fee-recipient=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
