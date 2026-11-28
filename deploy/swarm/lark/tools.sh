#!/usr/bin/env bash
# Extract the pinned mnemonic generator; never start a container or service.
set -euo pipefail
[[ $# == 1 || $# == 2 ]] || { echo 'usage: tools.sh OUTPUT_DIRECTORY [PINNED_EEZ_DEPLOY_TOOL_IMAGE]' >&2; exit 2; }
if [[ $# == 2 ]]; then
    [[ "$2" =~ ^(sha256:|[a-z0-9./:_-]+@sha256:)[0-9a-f]{64}$ ]] || {
        echo 'Foundry extraction requires an immutable deployment-tool image reference.' >&2; exit 2;
    }
fi
image=ethpandaops/ethereum-genesis-generator@sha256:017f8bdbd454d2fcf4e0f65f6c64b5bc4c991f5846220e9be188145fa85875db
[[ -d "$1" ]] || install -d -m 0755 "$1"
verify() {
    printf '%s  %s\n' 7593a0e7e2d14aed8ebb47f919c77dc73efdc2a15948be2a5ddfe934c9b6c37d "$1/eth2-val-tools" | sha256sum -c -
}
container=''
trap 'if [[ -n "$container" ]]; then docker rm "$container" >/dev/null; fi' EXIT
if [[ ! -e "$1/eth2-val-tools" ]]; then
    docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image"
    container="$(docker create "$image")"
    docker cp "$container:/usr/local/bin/eth2-val-tools" "$1/eth2-val-tools"
    docker rm "$container" >/dev/null
    container=''
fi
verify "$1"
if [[ $# == 2 ]]; then
    if [[ ! -e "$1/cast" ]]; then
        docker image inspect "$2" >/dev/null
        container="$(docker create "$2")"
        docker cp -L "$container:/root/.foundry/bin/cast" "$1/cast"
        docker rm "$container" >/dev/null
        container=''
    fi
    printf '%s  %s\n' ccd95a4607ca3ebfcb88bb90e7235cdb7f0564f5f1afa17478d5fccabbb222cb "$1/cast" | sha256sum -c -
fi
