# Local cross-chain validation

Run against the existing [L1/PBS](PBS.md) and [L2](L2.md), from the repository
root. This finite Swarm job spends fixture gas and deploys test contracts on
L1 **414141** / L2 **424242**; it does not deploy another rollup.

It exercises `counter` (L1→L2), `counterL2` (L2→L1) and `nestedCounter`
(L1→L2→L1). Require execution/state-table checks **and** independent canonical
receipt, causal, KZG/blob, native-semantics and signed-trigger checks to pass.

## Run

Enable [fee quotes in both directions](L2.md#fees-and-quotes) first and wait for
Composer rollout/catch-up. Select an existing validation image matching the
running deployment's protocol/contracts and the checkout mounted below.
The image must include GNU awk for evidence collection.

Create these compiler caches once for Core pin `84a5b520`; use new cache names
and update the job definition for a different pin:

```sh
sudo docker volume create eez-devnet-protocol-84a5b520-out
sudo docker volume create eez-devnet-protocol-84a5b520-cache
```

Choose a unique evidence volume for each run; a started directory cannot be
reused. Do not run workloads sharing funding accounts concurrently.

```sh
validation_image=YOUR_VALIDATION_IMAGE
stamp=$(date -u +%y%m%d%H%M)
evidence="eez-devnet-validation-$stamp"
sudo docker volume create "$evidence"
sudo env "EEZ_DEVNET_VALIDATION_IMAGE=$validation_image" \
  "EEZ_DEVNET_VALIDATION_VOLUME=$evidence" "EEZ_DEVNET_CHECKOUT=$PWD" \
  docker stack deploy --detach=true --resolve-image never \
  -c deploy/swarm/local/checks/cross-chain.yml "eez-devnet-validation-$stamp"
sudo docker service ps "eez-devnet-validation-${stamp}_check" --no-trunc
sudo docker service logs -f "eez-devnet-validation-${stamp}_check"
```

Require `Complete`, exit 0 and passing `protocol-e2e/summary.json` in the evidence
volume. Retain failures before retrying. The volume holds normalized logs,
JSON evidence, raw Beacon responses and checker hashes. Worker wallet files
remain in the disposable task filesystem; do not copy that filesystem wholesale.

This job is visible in Swarmpit and excluded from daily `up` / `down`.
It mounts deployment/Git metadata read-only, without node datadirs, Docker socket
or published ports. The first run compiles fixtures; later runs reuse the caches.

## Build tooling only when needed

Use an initialized protocol checkout and a matching deploy image. The validation
image inherits that image's contract/compiler snapshot; rebuild the deploy base
when those sources change. Record uncommitted build inputs separately.

```sh
revision=$(git rev-parse HEAD)
protocol=$(git ls-tree HEAD eez-core-protocol | awk '{print $3}')
tag=${revision:0:8}
deploy_image=YOUR_MATCHING_DEPLOY_IMAGE
validation_image="eez-devnet-validation:$tag"
sudo docker buildx build --builder default --platform linux/amd64 \
  --resource cpu-period=100000 --resource cpu-quota=400000 \
  --resource memory=24g --resource memory-swap=24g \
  --build-arg "DEPLOY_IMAGE=$deploy_image" \
  --label org.opencontainers.image.revision="$revision" \
  --label io.eez.protocol.revision="$protocol" \
  --load -f deploy/swarm/local/checks/Dockerfile.validation \
  -t "$validation_image" .
```

These are local development tools, not CI-qualified release artifacts.

## Scope

This exercises three selected scenarios. It does not qualify the full protocol
suite, builder-refund negative controls, independent follower replay, crash/queue
durability, isolated restore or ZisK proving. Keep run results outside versioned
documentation; ignored `artifacts/` directories and Docker evidence volumes are
local records, unavailable to a fresh checkout.
