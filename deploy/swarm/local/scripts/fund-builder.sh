#!/usr/bin/env bash
# One-shot fixture funding after fresh genesis; never retried automatically.
set -euo pipefail
source /l2-fixtures.env
rpc=http://execution:8545
[[ "$(timeout 10 cast chain-id --rpc-url "$rpc")" == 414141 ]]
tx=$(timeout 30 cast send 0xb9e79D19f651a941757b35830232E7EFC77E1c79 \
    --value 100ether --private-key "$EEZ_L1_POSTER_KEY" --rpc-url "$rpc" --async)
timeout 120 cast receipt "$tx" --rpc-url "$rpc" --confirmations 1 --json |
    jq -e '.status == "0x1"' >/dev/null
echo "Funded public builder fixture with 100 test ETH: $tx"
