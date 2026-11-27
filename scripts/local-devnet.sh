#!/usr/bin/env bash
# Server-local Swarm lifecycle; run with Docker administration permissions.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo/deploy/swarm/local"
image=ethpandaops/ethereum-genesis-generator@sha256:017f8bdbd454d2fcf4e0f65f6c64b5bc4c991f5846220e9be188145fa85875db
stack=eez-devnet
prep=eez-devnet-414141-prep
# Explicit runtime ownership: never scale preparation, deployment or probe jobs.
runtime_services=(
    eez-devnet_execution eez-devnet_beacon eez-devnet_validator
    eez-devnet-pbs_postgres eez-devnet-pbs_redis
    eez-devnet-pbs_relay-housekeeper eez-devnet-pbs_relay-api
    eez-devnet-builder_builder eez-devnet-builder_builder-beacon
    eez-devnet-boost_mev-boost
    eez-devnet-l2_eez-proof-signer eez-devnet-l2_eez-beacon eez-devnet-l2_eez-node
)
explorer_apps=(
    eez-devnet-explorers_l1-blockscout eez-devnet-explorers_l2-blockscout
    eez-devnet-explorers_l1-web eez-devnet-explorers_l2-web
    eez-devnet-explorers_l1-gateway eez-devnet-explorers_l2-gateway
    eez-devnet-explorers_verifier
)

scale_group() {
    local wanted="$1" service states state running active deadline
    shift
    local targets=()
    for service in "$@"; do targets+=("$service=$wanted"); done
    docker service scale --detach=true "${targets[@]}"
    deadline=$((SECONDS + wait_seconds))
    for service in "$@"; do
        while true; do
            states="$(docker service ps --no-trunc --format '{{.CurrentState}}' "$service")"
            running=0
            active=0
            while IFS= read -r state; do
                case "$state" in
                    Running*) running=$((running + 1)); active=$((active + 1)) ;;
                    New*|Pending*|Assigned*|Accepted*|Preparing*|Ready*|Starting*) active=$((active + 1)) ;;
                esac
            done <<< "$states"
            if ((wanted == 0 && active == 0)) || ((wanted == 1 && running == 1 && active == 1)); then
                echo "$service: $running running task(s)"
                break
            fi
            if ((SECONDS >= deadline)); then
                echo "Timed out waiting for $service to reach $wanted running task(s); inspect its tasks/logs. No automatic reset." >&2
                return 1
            fi
            sleep 2
        done
    done
}

case "${1:-}" in
    reset)
        exec python3 "$repo/deploy/swarm/local/scripts/reset.py" "${@:2}"
        ;;
    up|down)
        wait_seconds="${EEZ_DEVNET_WAIT_SECONDS:-180}"
        [[ "$wait_seconds" =~ ^[1-9][0-9]{0,3}$ ]] || { echo 'EEZ_DEVNET_WAIT_SECONDS must be 1..9999.' >&2; exit 1; }
        # Check the entire installation before making a partial lifecycle change.
        docker service inspect "${runtime_services[@]}" >/dev/null
        have_explorers=false
        if docker service inspect eez-devnet-explorers_postgres >/dev/null 2>&1; then
            docker service inspect "${explorer_apps[@]}" >/dev/null
            have_explorers=true
        fi
        if [[ "$1" == down ]]; then
            if "$have_explorers"; then scale_group 0 "${explorer_apps[@]}"; fi
            scale_group 0 eez-devnet-l2_eez-node
            scale_group 0 eez-devnet_validator
            scale_group 0 eez-devnet-l2_eez-beacon eez-devnet-l2_eez-proof-signer \
                eez-devnet-builder_builder-beacon eez-devnet-builder_builder \
                eez-devnet-boost_mev-boost eez-devnet-pbs_relay-api eez-devnet-pbs_relay-housekeeper
            scale_group 0 eez-devnet_beacon
            scale_group 0 eez-devnet_execution eez-devnet-pbs_postgres eez-devnet-pbs_redis
            if "$have_explorers"; then scale_group 0 eez-devnet-explorers_postgres; fi
            echo 'Devnet stopped. All volumes, secrets, images and deployment records retained.'
        else
            scale_group 1 eez-devnet-pbs_postgres eez-devnet-pbs_redis eez-devnet_execution
            if "$have_explorers"; then scale_group 1 eez-devnet-explorers_postgres; fi
            scale_group 1 eez-devnet_beacon eez-devnet-boost_mev-boost eez-devnet-l2_eez-proof-signer
            scale_group 1 eez-devnet-pbs_relay-housekeeper eez-devnet-pbs_relay-api \
                eez-devnet-builder_builder eez-devnet-builder_builder-beacon
            scale_group 1 eez-devnet_validator
            scale_group 1 eez-devnet-l2_eez-beacon eez-devnet-l2_eez-node
            if "$have_explorers"; then scale_group 1 "${explorer_apps[@]}"; fi
            echo 'Devnet runtime tasks started. Run check-all for RPC/consensus readiness; task state alone is not semantic validation.'
        fi
        ;;
    status-all)
        for component in eez-devnet eez-devnet-pbs eez-devnet-builder eez-devnet-boost eez-devnet-l2 eez-devnet-explorers; do
            docker service ls --filter "label=com.docker.stack.namespace=$component"
        done
        ;;
    explorer-prepare)
        for role in postgres l1 l2; do
            secret="eez-devnet-explorer-$role-password"
            if ! docker secret inspect "$secret" >/dev/null 2>&1; then
                openssl rand -hex 32 | docker secret create "$secret" -
            fi
        done
        for chain in l1 l2; do
            secret="eez-devnet-explorer-$chain-web-secret"
            if ! docker secret inspect "$secret" >/dev/null 2>&1; then
                openssl rand -base64 64 | docker secret create "$secret" -
            fi
        done
        for volume in eez-devnet-explorers-postgres eez-devnet-414141-explorer-cache eez-devnet-424242-explorer-cache; do
            docker volume create "$volume"
        done
        ;;
    explorer-start)
        : "${EEZ_DEVNET_BLOCKSCOUT_IMAGE:?Select the built backend fork image}"
        : "${EEZ_DEVNET_EXPLORER_FRONTEND_IMAGE:?Select a compatible frontend image}"
        files=(-c stacks/explorers.yml)
        case "${EEZ_DEVNET_EXPLORER_ACCESS-overlay}" in
            overlay) ;;
            private-host)
                systemctl is-active --quiet eez-explorer-private-ports.service || {
                    echo 'Install and start explorer-private-ports.service before publishing backends.' >&2
                    exit 1
                }
                files+=(-c stacks/explorers-access.yml)
                ;;
            *) echo 'EEZ_DEVNET_EXPLORER_ACCESS must be overlay or private-host.' >&2; exit 1 ;;
        esac
        docker stack deploy --detach=true --resolve-image never "${files[@]}" eez-devnet-explorers
        ;;
    explorer-stop)
        wait_seconds=180
        docker service inspect eez-devnet-explorers_postgres "${explorer_apps[@]}" >/dev/null
        scale_group 0 "${explorer_apps[@]}"
        scale_group 0 eez-devnet-explorers_postgres
        ;;
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
        docker stack deploy --detach=true -c stacks/prepare.yml "$prep"
        echo "Inspect preparation: docker service ps ${prep}_prepare --no-trunc"
        ;;
    start)
        # A completed preparation is required; starting clients never generates genesis.
        state="$(docker service ps --no-trunc --format '{{.CurrentState}}' "${prep}_prepare")"
        [[ "$state" == Complete* ]] || { echo 'Require successful preparation before starting.' >&2; exit 1; }
        docker stack deploy --detach=true -c stacks/l1.yml "$stack"
        ;;
    status)
        docker service ls --filter "name=$stack"
        for role in execution beacon validator; do
            docker service ps "${stack}_$role" --no-trunc
        done
        ;;
    check|check-pbs|check-all)
        # New immutable config/task per run preserves the script and its evidence.
        stamp="$(date -u +%y%m%d%H%M%S)"
        config="eez-devnet-check-$stamp"
        probe="eez-devnet-check-$stamp"
        check_script=checks/check.sh
        attempts=80
        if [[ "$1" == check-pbs ]]; then
            check_script=checks/check-pbs.sh
            attempts=60
        fi
        mounts=()
        configs=(--config "source=$config,target=/check.sh")
        command="bash /check.sh"
        docker config create "$config" "$check_script"
        if [[ "$1" == check-all ]]; then
            docker config create "$config-pbs" checks/check-pbs.sh
            docker config create "$config-l2" checks/check-l2.sh
            configs+=(--config "source=$config-pbs,target=/check-pbs.sh" --config "source=$config-l2,target=/check-l2.sh")
            mounts+=(--mount type=volume,source=eez-devnet-424242-deployment,target=/out,readonly)
            command+=' && bash /check-pbs.sh && bash /check-l2.sh'
        fi
        docker service create --detach=true --name "$probe" --restart-condition none \
            --constraint node.labels.platform.data==true \
            --log-driver json-file --log-opt max-size=20m --log-opt max-file=3 \
            --network eez-devnet_l1 "${configs[@]}" "${mounts[@]}" \
            --entrypoint bash "$image" -c \
            "for ((attempt=1; attempt<=$attempts; attempt++)); do $command && exit 0; sleep 12; done; exit 1"
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
        docker stack deploy --detach=true --resolve-image never -c stacks/l2-deploy.yml eez-devnet-l2-deploy
        ;;
    l2-start)
        : "${EEZ_DEVNET_NODE_IMAGE:?Select the built node image}"
        : "${EEZ_DEVNET_SIGNER_IMAGE:?Select the built signer image}"
        state="$(docker service ps --no-trunc --format '{{.CurrentState}}' eez-devnet-l2-deploy_deploy)"
        [[ "$state" == Complete* ]] || { echo 'Require successful L2 deployment before starting.' >&2; exit 1; }
        docker stack deploy --detach=true --resolve-image never -c stacks/l2.yml eez-devnet-l2
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
        echo 'usage: bash scripts/local-devnet.sh reset [--yes]|up|down|status-all|check-all|prepare|start|status|check|check-pbs|stop|l2-deploy|l2-start|l2-status|l2-stop|explorer-prepare|explorer-start|explorer-stop' >&2
        exit 2
        ;;
esac
