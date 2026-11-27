#!/usr/bin/env bash
set -euo pipefail
exec lighthouse bn --testnet-dir=/genesis/metadata --datadir=/beacon \
    --execution-endpoint=http://eez-node:18551 --execution-jwt=/run/secrets/engine-jwt \
    --http --http-address=0.0.0.0 --http-port=5252 --enable-private-discovery \
    --boot-nodes="$(< /pbs/beacon-peer.txt)" \
    --libp2p-addresses="$(< /pbs/beacon-peer.txt)" \
    --checkpoint-sync-url=http://beacon:5052 --supernode --subscribe-all-subnets \
    --suggested-fee-recipient=0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
