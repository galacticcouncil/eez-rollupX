# Deployment files

| Directory | Purpose |
| --- | --- |
| [networks/](networks/README.md) | Public local/Lark/Chiado intent manifests and release planning. |
| [swarm/components/](swarm/components/README.md) | Reusable PBS, rollup and explorer startup code for Swarm. |
| [swarm/local/](swarm/local/README.md) | The running local testnet: concrete stacks, public fixtures, setup and checks. |
| [swarm/lark/](swarm/lark/README.md) | Lark assembly requirements and the shared components to reuse. |
| [explorers/](explorers/README.md) | Existing standalone Chiado Compose explorer assets; browser bootstrap also used by Swarm. |

Use [scripts/local-devnet.sh](../scripts/local-devnet.sh) from the repository root
for daily local operations. Network intent does not yet render Lark stacks.
Lark deployment will use the Swarmpit API, separately from image build/testing.
The [Swarm layout guide](swarm/README.md) explains component boundaries.
