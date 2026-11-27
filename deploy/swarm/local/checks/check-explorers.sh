#!/usr/bin/env bash
# Read-only check from inside the explorer overlay; no host access is required.
set -euo pipefail
for chain in l1 l2; do
    base="http://$chain-gateway:8080"
    curl -fsS --max-time 10 -o /dev/null "$base/"
    blocks=$(curl -fsS --max-time 10 "$base/api/v2/stats" | jq -er '.total_blocks | tonumber')
    ((blocks > 0)) || { echo "$chain explorer has not indexed blocks yet." >&2; exit 1; }
    echo "$chain explorer homepage/API ready; indexed blocks=$blocks"
done
