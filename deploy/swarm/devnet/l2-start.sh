#!/bin/sh
set -eu
test -f /out/deployment-complete
(cd / && sha256sum -c /out/deployment.sha256)
set -a
. /out/deployments.env
. /l2-fixtures.env
set +a
case "$1" in
    signer)
        exec eez-proof-signer --listen-addr=0.0.0.0:50061 \
            --chain-config=/out/l2-genesis.json \
            --l1-chain-config=/out/l1-genesis.json --max-request-blocks=1024
        ;;
    node)
        export EEZ_L1_TRUSTED_PEERS="$(cat /pbs/execution-peer.txt)"
        exec eez-composer node --chain=/out/l2-genesis.json --datadir=/data/l2 \
            --log.stdout.format=json --log.file.max-files=0 \
            --http --http.addr=0.0.0.0 --http.port=18688 --http.api=eth,net,web3,debug,trace \
            --authrpc.addr=127.0.0.1 --authrpc.port=18684 \
            --port=30640 --discovery.port=30640 --discovery.v5.port=30641 \
            --ipcdisable --disable-discovery
        ;;
    *) exit 2 ;;
esac
