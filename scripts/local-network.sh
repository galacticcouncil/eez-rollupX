#!/usr/bin/env bash
# Start, test and stop the local Hydration network in docker-compose.local.yml:
# the Composer's built-in L1, Hydration rules, three signers, threshold two.
# See docs/runbooks/local-network.md.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
# Pin the project: a COMPOSE_PROJECT_NAME in the checkout's .env (the Chiado
# runbook sets one) would otherwise point `reset` at another stack.
compose() { docker compose -p eez-local -f docker-compose.local.yml "$@"; }

usage() {
    cat <<'EOF'
usage: scripts/local-network.sh <command>
  up      build the images, create the network on first use, start it
  test    run the outside test (scripts/local-network/test-counter-relay.sh)
  status  show the services and both chain heights
  logs    follow logs (default: composer), e.g. "logs signer-2"
  down    stop the network and keep its chain data
  reset   stop the network and delete its chain data
EOF
}

rpc_result() {
    curl -sf -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":[]}" "$1" \
        | sed -n 's/.*"result":"\([^"]*\)".*/\1/p'
}

roster_exists() {
    compose run --rm --no-deps --entrypoint test init -f /state/roster.env 2>/dev/null
}

up() {
    [[ -f eez-core-protocol/foundry.toml ]] || {
        echo "Initialize the protocol first: git submodule update --init --recursive eez-core-protocol" >&2
        exit 1
    }
    # The deploy image copies the genesis tools out of the node image: build it last.
    compose build composer
    compose build signer-1
    compose build init
    compose run --rm init
    compose up -d --wait signer-1 signer-2 signer-3 builder-stub beacon composer
    if ! roster_exists; then
        compose run --rm contracts
        # Restart the Composer so it reads roster.env and asks all three signers.
        compose up -d --wait --force-recreate --no-deps composer
    fi
    echo "Waiting for the L2 RPC..."
    for _ in $(seq 90); do
        [[ -n "$(rpc_result http://127.0.0.1:18688 eth_chainId)" ]] && break
        sleep 2
    done
    [[ -n "$(rpc_result http://127.0.0.1:18688 eth_chainId)" ]] || {
        echo "L2 RPC did not start; check: scripts/local-network.sh logs" >&2
        exit 1
    }
    cat <<'EOF'

Local network is up (public development keys only: see x-keys in docker-compose.local.yml).
  L2 RPC             http://127.0.0.1:18688  chain 1338
  L1 RPC             http://127.0.0.1:18545  chain 1337 (through the bundle stub)
  L2 front (L2->L1)  http://127.0.0.1:18998
  L1 front (L1->L2)  http://127.0.0.1:18999
Run the outside test with: scripts/local-network.sh test
EOF
}

status() {
    compose ps
    echo "L1 height: $(rpc_result http://127.0.0.1:18545 eth_blockNumber)"
    echo "L2 height: $(rpc_result http://127.0.0.1:18688 eth_blockNumber)"
}

case "${1:-}" in
    up) up ;;
    test) compose run --rm test ;;
    status) status ;;
    logs) shift; compose logs -f "${@:-composer}" ;;
    down) compose down ;;
    reset) compose down --volumes --remove-orphans ;;
    *) usage; exit 1 ;;
esac
