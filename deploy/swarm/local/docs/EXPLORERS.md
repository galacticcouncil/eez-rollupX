# Local L1/L2 explorers

Both explorers use Blockscout, separate frontends and separate application
databases in their own stack-contained PostgreSQL. They add eight services.
Run commands from the repository root after [L2 setup](L2.md).

## Install once

Use existing compatible images: the backend is built from the
`blockscout-eez` fork and the frontend from Blockscout frontend sources.
Select their actual local tags; these commands do not build them.

```sh
sudo bash scripts/local-devnet.sh explorer-prepare
```

For private host access, install the Docker-aware firewall helper **before**
publishing the backend ports:

```sh
sudo install -m 0755 deploy/swarm/local/access/explorer-private-ports.sh /usr/local/sbin/eez-explorer-private-ports
sudo install -m 0644 deploy/swarm/local/access/explorer-private-ports.service /etc/systemd/system/eez-explorer-private-ports.service
sudo systemctl daemon-reload
sudo systemctl enable --now eez-explorer-private-ports.service
sudo env EEZ_DEVNET_BLOCKSCOUT_IMAGE=YOUR_BACKEND_IMAGE \
  EEZ_DEVNET_EXPLORER_FRONTEND_IMAGE=YOUR_FRONTEND_IMAGE \
  EEZ_DEVNET_EXPLORER_ACCESS=private-host \
  bash scripts/local-devnet.sh explorer-start
sudo docker stack services eez-devnet-explorers
```

Omit `EEZ_DEVNET_EXPLORER_ACCESS` for overlay-only access without host ports.
The firewall helper reserves ports **18110** (L2) and **18112** (L1); choose another
access arrangement if those ports are already owned.

## Open and check

For the private-host profile, tunnel from your workstation:

```sh
ssh -N -L 18110:127.0.0.1:18110 -L 18112:127.0.0.1:18112 USER@SERVER
```

Open `http://localhost:18110` for L2 or `http://localhost:18112` for L1.
On the server, check each homepage and indexer API:

```sh
curl -fsS -o /dev/null http://127.0.0.1:18110/
curl -fsS http://127.0.0.1:18110/api/v2/stats
curl -fsS -o /dev/null http://127.0.0.1:18112/
curl -fsS http://127.0.0.1:18112/api/v2/stats
```

For either access profile, submit the overlay readiness job and require `Complete`/exit 0:

```sh
sudo bash scripts/local-devnet.sh check-explorers
```

For permanent tailnet access, inspect `tailscale serve status` first. If HTTPS
ports 8444/8445 are free, add these routes while preserving existing routes:

```sh
sudo tailscale serve --bg --https=8444 http://127.0.0.1:18110
sudo tailscale serve --bg --https=8445 http://127.0.0.1:18112
```

Use the URLs shown by `tailscale serve status`. Keep access tailnet-only.
A healthy HTTP response does not establish that indexing has caught up; compare
the displayed heads and known receipts with canonical RPC.

## Stop and retain

Daily [full-network commands](../README.md#run-check-and-stop) include installed
explorers. `explorer-stop` stops only their eight services. Preserve the explorer
PostgreSQL volume and its Swarm secrets together; the shared server database
and backup job do not cover it. Solidity source verification is enabled; Vyper is disabled for this pinned verifier.
