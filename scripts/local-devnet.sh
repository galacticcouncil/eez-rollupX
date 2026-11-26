#!/usr/bin/env bash
# Server-local Swarm lifecycle; run with Docker administration permissions.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo/deploy/swarm/devnet"
image=ethpandaops/ethereum-genesis-generator@sha256:017f8bdbd454d2fcf4e0f65f6c64b5bc4c991f5846220e9be188145fa85875db
stack=eez-devnet
prep=eez-devnet-414141-prep
case "${1:-}" in
    prepare)
        if docker service inspect "${prep}_prepare" >/dev/null 2>&1; then
            echo 'Preparation already exists. Inspect its result; never regenerate existing state.' >&2
            exit 1
        fi
        for role in genesis execution beacon validators; do
            docker volume create "eez-devnet-414141-$role"
        done
        if ! docker secret inspect eez-devnet-engine-jwt >/dev/null 2>&1; then
            openssl rand -hex 32 | docker secret create eez-devnet-engine-jwt -
        fi
        docker stack deploy --detach=true -c prepare.yml "$prep"
        echo "Inspect preparation: docker service ps ${prep}_prepare --no-trunc"
        ;;
    start)
        # A completed preparation is required; starting clients never generates genesis.
        state="$(docker service ps --no-trunc --format '{{.CurrentState}}' "${prep}_prepare")"
        [[ "$state" == Complete* ]] || { echo 'Require successful preparation before starting.' >&2; exit 1; }
        docker stack deploy --detach=true -c stack.yml "$stack"
        ;;
    status)
        docker service ls --filter "name=$stack"
        for role in execution beacon validator; do
            docker service ps "${stack}_$role" --no-trunc
        done
        ;;
    check|check-pbs)
        # New immutable config/task per run preserves the script and its evidence.
        stamp="$(date -u +%y%m%d%H%M%S)"
        config="eez-devnet-check-$stamp"
        probe="eez-devnet-check-$stamp"
        check_script=check.sh
        attempts=80
        if [[ "$1" == check-pbs ]]; then
            check_script=check-pbs.sh
            attempts=60
        fi
        docker config create "$config" "$check_script"
        docker service create --detach=true --name "$probe" --restart-condition none \
            --network eez-devnet_l1 --config "source=$config,target=/check.sh" \
            --entrypoint bash "$image" -c \
            "for ((attempt=1; attempt<=$attempts; attempt++)); do bash /check.sh && exit 0; sleep 12; done; exit 1"
        echo "Monitor check: docker service logs -f $probe"
        echo "Check task exit: docker service ps $probe --no-trunc"
        ;;
    stop)
        docker service scale --detach=true "${stack}_validator=0" "${stack}_beacon=0" "${stack}_execution=0"
        ;;
    l2-deploy)
        : "${EEZ_DEVNET_DEPLOY_IMAGE:?Build and select the deployment image first}"
        if docker service inspect eez-devnet-l2-deploy_deploy >/dev/null 2>&1; then
            echo 'L2 deployment already submitted. Inspect receipts; do not broadcast again.' >&2
            exit 1
        fi
        for role in deployment broadcast node beacon; do
            docker volume create "eez-devnet-424242-$role"
        done
        docker stack deploy --detach=true --resolve-image never -c l2-deploy.yml eez-devnet-l2-deploy
        ;;
    l2-start)
        : "${EEZ_DEVNET_NODE_IMAGE:?Select the built node image}"
        : "${EEZ_DEVNET_SIGNER_IMAGE:?Select the built signer image}"
        state="$(docker service ps --no-trunc --format '{{.CurrentState}}' eez-devnet-l2-deploy_deploy)"
        [[ "$state" == Complete* ]] || { echo 'Require successful L2 deployment before starting.' >&2; exit 1; }
        docker stack deploy --detach=true --resolve-image never -c l2.yml eez-devnet-l2
        ;;
    l2-status)
        for role in eez-node eez-proof-signer eez-beacon; do
            docker service ps "eez-devnet-l2_$role" --no-trunc
        done
        ;;
    l2-stop)
        docker service scale --detach=true eez-devnet-l2_eez-node=0 \
            eez-devnet-l2_eez-beacon=0 eez-devnet-l2_eez-proof-signer=0
        ;;
    *)
        echo 'usage: bash scripts/local-devnet.sh prepare|start|status|check|check-pbs|stop|l2-deploy|l2-start|l2-status|l2-stop' >&2
        exit 2
        ;;
esac
