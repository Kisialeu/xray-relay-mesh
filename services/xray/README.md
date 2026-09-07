# Xray node service

This directory contains only the runtime payload for an Xray node:

- `compose.yml` - Xray, Warp, AdGuard Home, and optional Hysteria2
- `entrypoint.sh` - Xray container entrypoint
- `stats.py` - node-local protocol statistics endpoint
- `xray-logrotate.conf` - log rotation policy
- `xray-restart.cron` - scheduled Xray and Warp restart

Deployment control is implemented in `bashbuild/components/xray/`. Host prerequisites are managed explicitly by `infrastructure/host/bootstrap.sh`.

## Managed and persistent paths

The controller deploys managed files under `/opt/xray-node` using a deterministic manifest. These files participate in compare, promotion, backup, and rollback.

Persistent paths are excluded from the manifest:

- `/opt/xray-node/adguard/work`
- `/opt/xray-node/hysteria/acme`
- `/opt/xray-node/logs`

## Secrets

Deployment requires Reality keys and Hysteria statistics secrets to already exist in `configs/inventory.json`. It never generates, rotates, persists, or logs those values.

All Hysteria-enabled nodes must contain the same `hysteria_stats_secret`. Validation reports missing or divergent fields without printing their contents.

Secret-bearing rendered files use mode `0600`:

- `.env`
- `config/config.json`
- `hysteria/config.yaml`

## Deployment lifecycle

For each node the controller performs:

1. Render and create a deterministic managed manifest.
2. Verify remote Docker, Compose, BBR, cron, zstd, and UDP buffers where applicable.
3. Acquire the remote deployment lock.
4. Upload to `/opt/xray-node/.staging/<run-id>`.
5. Validate Compose, Xray configuration, and Hysteria configuration.
6. Compare the staged manifest with the active manifest.
7. Back up and promote managed files when changed.
8. Reconcile Compose without `docker compose down`.
9. Verify containers and the node-local statistics endpoint.
10. Restore the managed backup if apply or verification fails.

Commands:

```bash
./mesh.sh render xray --node NAME --output DIR
./mesh.sh plan xray --node NAME
./mesh.sh deploy xray --node NAME
./mesh.sh rollback xray --node NAME
```
