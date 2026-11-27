#!/usr/bin/env bash
# Extract the pinned mnemonic generator; never start a container or service.
set -euo pipefail
[[ $# == 1 ]] || { echo 'usage: tools.sh OUTPUT_DIRECTORY' >&2; exit 2; }
image=ethpandaops/ethereum-genesis-generator@sha256:017f8bdbd454d2fcf4e0f65f6c64b5bc4c991f5846220e9be188145fa85875db
install -d -m 0755 "$1"
verify() {
    printf '%s  %s\n' 7593a0e7e2d14aed8ebb47f919c77dc73efdc2a15948be2a5ddfe934c9b6c37d "$1/eth2-val-tools" | sha256sum -c -
}
if [[ -e "$1/eth2-val-tools" ]]; then verify "$1"; exit; fi
docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image"
container="$(docker create "$image")"
trap 'docker rm "$container" >/dev/null' EXIT
docker cp "$container:/usr/local/bin/eth2-val-tools" "$1/eth2-val-tools"
verify "$1"
