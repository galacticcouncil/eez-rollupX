#!/bin/sh
set -eu
exec /app/rbuilder node --chain=/genesis/metadata/genesis.json --datadir=/builder \
    --http --http.addr=0.0.0.0 --http.api=eth,net,web3,flashbots,admin \
    --authrpc.addr=0.0.0.0 --authrpc.jwtsecret=/run/secrets/engine-jwt \
    --trusted-peers="$(/busybox cat /pbs/execution-peer.txt)" --disable-discovery \
    --rbuilder.config=/pbs/builder.toml --engine.persistence-threshold=0 \
    --engine.memory-block-buffer-target=0 --txpool.no-local-transactions-propagation \
    --rpc.eth-proof-window=3 --builder.gaslimit=60000000
