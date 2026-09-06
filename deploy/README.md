# XRay Deploy Module

Idempotent SSH-based deployment system for distributed XRay relay nodes with AdGuard Home, WARP integration, Prometheus metrics, and automatic fail-safe rollback.

## Overview

This module deploys XRay-compatible proxy nodes to remote hosts via SSH, managing the full stack:
- **XRay** - VLESSReality protocol with DNS routing, Geo-blocking, and user management
- **AdGuard Home** - Built-in DNS-based ad/malware filtering
- **WARP** - Cloudflare WARP exit for additional tunneling capability
- **Stats Export** - Prometheus-compatible metrics server

All deployments are driven from a single `inventory.json` source of truth. No manual per-node configuration required.

---

## Quick Start

```bash
cd /path/to/relay-mesh/deploy

# Deploy to all nodes defined in inventory.json
SSH_KEY=~/.ssh/my_key_name MESH_WEBHOOK_URL=https://your-webhook-url ./deploy_nodes.sh all

# Deploy to a specific node
./deploy_nodes.sh <node-name>

# Remove a node (use stats branch's remove-node/remove_node.sh)
```

### Environment Variables

| Var | Required | Default | Description |
|-----|----------|---------|-------------|
| `SSH_KEY` | No | Node-specific from inventory | Path to SSH private key (~ expanded) |
| `SSH_USER` | No | Node-specific | Username on remote (default: root for most providers) |
| `XRAY_DEPLOY_DIR` | No | `/opt/xray-node` | Remote deploy directory per node |
| `MESH_WEBHOOK_URL` | No | - | Optional failure webhook (Slack/ntfy.sh) |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Local Machine (Hermes/HOST)                                 │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ deploy_nodes.sh                                        │  │
│  │  ↓                                                     │  │
│  │  render_xray_env()                                     │  │
│  │  render_xray_config_json()                             │  │
│  │  render_adguard_yaml()                                 │  │
│  └──────────────────────┬────────────────────────────────┘  │
│                         ↓                                    │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ deploy_nodes.sh: assets/                               │  │
│  │   stage/.env                                           │  │
│  │   stage/config/config.json                             │  │
│  │   stage/adguard/conf/AdGuardHome.yaml                  │  │
│  │   stage/entrypoint.sh                                   │  │
│  │   stage/stats.py                                        │  │
│  │   stage/docker-compose.yml                              │  │
│  └──────────────────────┬────────────────────────────────┘  │
│                         ↓ SSH/rsync                          │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ Remote Node: /opt/xray-node                            │  │
│  │   docker-compose up                                     │  │
│  │   ├── xray container (VLESSReality port, API on 10085)│  │
│  │   ├── adguard-home container (port 3000)               │  │
│  │   └── warp container                                    │  │
│  │   .env → stats.py HTTP server on 9091                  │  │
│  │   /etc/logrotate.d/xray                                 │  │
│  │   /etc/cron.d/xray-restart (every 12h)                 │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## Inventory.json Schema

See your root `inventory.json` for full schema. Key node fields:

| Field | Type | Example | Purpose |
|-------|------|---------|---------|
| `id` | int | 1 | Node identifier (also relay id) |
| `name` | string | "node-sg-01" | Stable machine ID |
| `friendly_name` | string | "Singapore" | Human label in apps |
| `host` | string | "1.2.3.4 or hostname" | SSH target |
| `direct_port` | int | 443 | XRay listening port (exposed externally) |
| `ssh_user` | string | root | Remote username |
| `ssh_key` | string | ~/.ssh/my_key_name | SSH authentication |
| `is_relay_entry` | bool | false | Public relay entry point? |

Reality keys and users shared across all nodes (XRay uses same settings everywhere):

```json
"xray": {
  "reality": {
    "private_key": "...",
    "public_key": "...",
    "short_id": "...",
    "sni": "sub.domain.com"
  },
  "dns": {
    "dns1": "...",
    "dns2": "..."
  },
  "users": [ ... ]
}
```

---

## Deploy Workflow

### Step 1: Reality Keys Generation (First Run Only)

If `inventory.json` lacks reality keys, they're generated locally via Docker and persisted back to inventory:

```bash
info "No Reality keys in inventory - generating (requires local docker)..."
docker run --rm teddysun/xray:latest xray x25519
# Extracts priv/pub from output and saves to inventory.json
```

**Alternative:** Set manually before deploy:
```json
"xray": {
  "reality": {
    "private_key": "...",
    "public_key": "...",
    "short_id": "...",
    "sni": "..."
  },
  ...
}
```

### Step 2: Dependency Checks (Per Node)

Before any config changes, the following are validated on remote host:

1. Docker daemon running
2. `docker compose` plugin installed
3. Required packages: `zstd`, `cron`
4. BBR congestion control enabled (or warning generated)

### Step 3: Signature Comparison (Idempotency Gate)

```bash
# Compute SHA256 of all staged files
sig=$(find "$stage_dir" -type f -exec sha256sum {} + | awk '{print $1}' | sort | sha256sum | awk '{print $1}')

# Compare to remote marker
if [ "$remote_sig" = "$sig" ]; then
    xray_ensure_running "$host" "$deploy_dir"  # No-op if unchanged
    return 0
fi
```

**Benefit:** If inventory hasn't changed (no new users, no config tweaks), containers restart only to self-heal after host reboot/updates.

### Step 4: Config Upload & Apply

Files uploaded via rsync merge strategy:

- Critical configs replaced
- `adguard/work/*` untouched (runtime state)
- `/opt/xray-node/logs/*` untouched (XRay writes here)

Remote finalization:
```bash
sudo mkdir -p ${deploy_dir}/logs ${deploy_dir}/adguard/work ${deploy_dir}/adguard/conf
sudo chmod +x ${deploy_dir}/entrypoint.sh
sudo chmod 644 *.env *config.json *docker-compose.yml
```

### Step 5: Stack Start & Verification

```bash
cd ${deploy_dir} && docker compose pull && \
docker compose down --remove-orphans && \
docker compose up -d

# Wait for container health check
sleep 3
for svc in adguard-home warp xray; do
    docker inspect -f '{{.State.Status}}' $svc | grep -q running || return 1
done
```

### Step 6: Marker Update

```bash
echo '${sig}' | sudo tee ${deploy_dir}/.deployed.sha256 > /dev/null
```

### Step 7: System Files Install

Creates two static files:

1. `/etc/logrotate.d/xray` - Daily rotation with zstd compression
   ```yaml
   /opt/xray-node/logs/*.log {
     daily
     rotate 7
     compress
     compressext .zst
     compressoptions -19 --rm
     postrotate
       docker kill --signal=USR1 xray    # Signal rotation
     endscript
   }
   ```

2. `/etc/cron.d/xray-restart` - Every 12h restart cron job
   ```bash
   0 */12 * * * root docker restart warp xray >> /var/log/xray-restart.log 2>&1
   ```

---

## Rollback Procedure (Automatic On Failure)

If stack fails to start after upload, immediate rollback executes:

```bash
# Take snapshot if deploy dir not empty
if [ -n "$(ls -A ${deploy_dir} 2>/dev/null)" ]; then
    sudo tar czf ${backup}.tgz -C $(dirname ${deploy_dir}) $(basename ${deploy_dir})
fi

# Failed start detected → rollback
xray_restore_backup "$host" "$deploy_dir" "${deploy_dir}.backup.tgz"

sudo rm -rf ${deploy_dir} && sudo tar xzf ${backup}.tgz -C $(dirname ${deploy_dir})
xray_start "$host" "$deploy_dir"     # Restart from backup
```

**Key points:**
- Backup named `*.deploy_dir.backup.tgz` persisted for manual recovery
- Cron job and logrotate restored in backup (not re-written, they're static)
- adguard/work runtime data preserved across rollback

---

## Remove Node Procedure

⚠️ **Critical:** Relay ports are reserved by node ID. Remove entry from inventory.json BEFORE deleting to avoid port conflicts:

```bash
# Step 1: Edit inventory.json - remove node entry
# Step 2: Delete from remote host (via stats branch tool)
./remove-node/remove_node.sh <node_id>
# Step 3: Redeploy remaining nodes if any config changes occurred
./deploy_nodes.sh all
```

---

## File Reference

### deploy_nodes.sh
Main orchestrator script. Entry point for deploy/rollback/remove operations.

### deploy_nodes.sh: generate_reality_keys_if_missing()
- Checks inventory.json reality keys field
- If empty: runs Docker locally to generate new Reality keys via `xray x25519`
- Parses output to extract private/public key pairs
- Persists back to inventory.json automatically
- Requires local Docker daemon available

### deploy_nodes.sh: deploy_one()
Per-node deployment function:
1. Parse inventory for node config
2. Resolve SSH credentials (override or per-node)
3. Create temporary staging directory
4. Render all configs (env, xray, adguard)
5. Copy asset files (entrypoint, stats.py, docker-compose, logrotate)
6. Run dependency checks (docker, compose, BBR, zstd/cron)
7. Upload config with signature compare
8. Apply or skip based on diff
9. Install system files (logrotate + cron job)
10. Track success/failure status

### assets/docker-compose.xray.yml
Static compose file shared across all nodes:
- Networks, ports exposed to `127.0.0.1:` (Docker controls external binding)
- Service order: adguard-home → warp → xray
- Volume mounts for config/logs/work directories
- entrypoint.sh mounted and executed on container start

### assets/entrypoint.sh
Simple bash script:
1. Install Python3 if missing (`apk add`)
2. Background stats.py HTTP server (metrics polling)
3. Exec xray run -confdir /etc/xray/(foreground takes over, process replaces shell)

### assets/stats.py
HTTP wrapper around XRay API gRPC endpoint:
- Listens on 9091, binds internally; Docker exposes externally
- Endpoints:
  - `/health` → `{"ok": true}`
  - `/online` → online user statistics
  - `/stats` → query-based stats (pattern: "user>>>")
- Handles timeouts/errors with appropriate HTTP codes

### assets/xray-logrotate.conf
Log rotation config for XRay log files:
- Daily rotation, keep 7 days
- zstd compression (-19 --rm)
- Postrotate signals container to flush logs (`USR1`)
- Installs via `mesh_upload_file` to `/etc/logrotate.d/xray`

### lib/xray_render.sh

render_xray_env():
- Reads inventory.json fields for node
- Outputs .env file with all image refs, keys, ports

render_xray_config_json():
- Constructs full config.json using jq templates (Variant E)
- Includes: api/stats services, DNS setup, VLESSReality inbound, fallback handling, routing rules
- All XRay inbounds share same realityKeys, sni, shortIds across nodes for client-side compatibility

render_adguard_yaml():
- Static AdGuard Home config (identical on all nodes)
- Same blocklists: AdGuard filters + OISD + StevenBlack hosts
- Custom rules to allow subscriber domain names
- HTTP listener with no logging to file

### lib/xray_ctl.sh

xray_check_docker() / xray_check_docker_compose():
- Delegates to common.sh mesh_* functions for validation

xray_check_remote_deps():
- Installs zstd/cron on apt/dnf/yum systems
- Logs failure if non-Linux or unsupported package manager

xray_check_bbr():
```bash
# Ensure BBR congestion control enabled
sudo modprobe tcp_bbr
echo 'tcp_bbr' | tee /etc/modules-load.d/bbr.conf
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
```

xray_container_running() / xray_stack_running():
- Validate all 3 containers running (self-healing after reboot)

xray_start():
- Full stack restart with health verification

xray_ensure_running():
- Only starts missing/failed services, leaves existing up

xray_apply():
- Core idempotent apply function with signature-based skip logic
- Upload merged configs → chmod fixes → start stack → verify → update marker

xray_restore_backup():
- Fail-safe rollback to tarball snapshot if start fails

xray_install_system_files():
- Copies logrotate.conf to `/etc/logrotate.d/xray`
- Writes cron job to `/etc/cron.d/xray-restart`

### common.sh (sourced from ../lib/)

mesh_resolve_ssh() / mesh_replace_subs_ssh():
```bash
# Resolves username/key with override precedence:
# 1. SSH_USER_OVERRIDE/SSH_KEY_OVERRIDE env vars
# 2. Per-node inventory.json fields
```

mesh_check_docker() / mesh_check_docker_compose():
- Runs docker info/compose version check via SSH
- Install if missing (curls get.docker.com or amazon-linux-extras)

mesh_upload_file() / mesh_upload_dir_merge():
```bash
# Upload strategy:
# 1. Stage to /tmp (user-writable) → scp_to host:/tmp/mesh_upload_$$_filename
# 2. sudo mv from /tmp to final dest (root-owned parent dir)
# 3. Force chmod fixes for readability by containers
# Fails fast with cleanup on error, no partial writes
```

mesh_ssh_opt():
```bash
# SSH options string for all remote commands:
"-i $SSH_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
```

---

## Operational Runbooks

### Adding a New Node

1. Edit `inventory.json` → nodes array
   ```json
   { "id": <next_id>, "name": "new-node-uuid", "friendly_name": "City", "host": "<ip-or-hostname>", "direct_port": <port>, "ssh_user": "<user>", "ssh_key": "~/.ssh/my_key_name" }
   ```

2. Deploy to new node:
   ```bash
   SSH_KEY=~/.ssh/my_key_name ./deploy_nodes.sh <node-name>
   ```

3. Verify with stats dashboard (if available) or test connection:
   ```bash
   # Test VLESSReality handshake to new port <port>
   curl -k --resolve <node-host>:<direct_port> "<domain>/sub"
   ```

### Removing a Node

⚠️ **Critical:** Reserved ports are free'd only after removing inventory entry. Delete first, then call remove-node script:

```bash
# Step 1: Edit inventory.json - remove node entry
# Step 2: Delete from remote host (via stats branch tool)
./remove-node/remove_node.sh <node_id>
# Step 3: Redeploy remaining nodes if any config changes occurred
./deploy_nodes.sh all
```

### Emergency Rollback

If deploy failed and automatic rollback insufficient:

```bash
# Manual rollback commands on remote host via SSH
host="<remote-hostname-or-ip>"
ssh <$SSH_USER>@"$host" "
  ls -la /opt/xray-node/*.backup.tgz    # List available backups
  sudo rm -rf /opt/xray-node            # Delete current (broken) deploy dir
  sudo tar xzf /opt/xray-node.backup.tgz -C / | grep 'xray-node:'   # Extract backup
"
```

### Rotation of Secrets

**Reality Keys:**
Generated once on first run, persisted to inventory.json. To regenerate:

```bash
# Delete reality keys from inventory.json (comment field "reality":)
./deploy_nodes.sh all     # Auto-generates new keys locally and persists
```

**AdGuard/Stats Tokens:**
Edit `inventory.json` in-place, redeploy affected nodes or switch_master.sh for stats role.

### Troubleshooting Checklist

| Symptom | Check | Fix |
|---------|-------|-----|
| Container won't start | `docker logs <container>`, `journalctl -u docker.service` | Verify Docker daemon health, check port conflicts |
| Deploy upload fails | SCP timeout? SSH key? | Test manual `scp -i $SSH_KEY ...`, verify key permissions |
| Stats not responding | Port mismatch? Docker exposes incorrectly? | Check container port vs host bind: `docker inspect xray \| grep Ports` |
| Clients can't connect | DNS/SNI mismatch? Reality keys expired? | Inspect client-side handshakes in XRay logs |
| adguard work state lost | Backup not preserved? | Verify `/opt/xray-node/adguard/work/` exists after deploy |
| Cron jobs missing | File permissions? Upload failed? | Run `xray_install_system_files()` manually and verify cron -l |

### Resource Usage Expectations

| Component | Memory | CPU (idle) | Notes |
|-----------|--------|------------|-------|
| xray container | ~30 MB | 5-10% | Grows with uplink stats buffering |
| adguard-home container | ~80 MB | 10-20% | Filters downloaded on each boot (~5MB) |
| warp container | ~60 MB | 8-15% | Requires /dev/net/tun device |
| stats.py HTTP server | ~20 MB | 2-5% | Minimal overhead per poll |

---

## Production Recommendations

### Version Pinning (Current uses :latest)

For stable deployments, pin container images:

```json
"images": {
  "xray": "teddysun/xray@sha256:<digest>",
  "warp": "caomingjun/warp@sha256:<digest>",
  "adguard": "adguard/adguardhome:latest"  # No digest, upstream supports rolling
}
```

Update `inventory.json` → `deploy_nodes.sh all`.

### External Port Security

Docker exposes stats via host port 9092, with HAProxy exposing only through token-authenticated /stats endpoint. Do NOT expose container's 127.0.0.1:10085 directly outside Docker network.

### Audit & Recovery

Available operations per node backup:
- Deployed config state in tarball (if rollback failed)
- Cron configuration via `/etc/cron.d/xray-restart`
- Logrotate rules via `/etc/logrotate.d/xray`

Recovery steps if remote host reformed/replaced:
1. Reinstall Docker and docker compose plugin
2. Recreate /opt/xray-node with backup or redeploy
3. Verify cron jobs functional (`cat /etc/cron.d/xray-restart`)

---

## Security Notes

⚠️ **Permission issues identified:**

Log directory `/opt/xray-node/logs` currently set `chmod 777` allowing any UID write access. Recommendation: tighten to `750` with root-owned group for log file writing while preventing arbitrary file execution. Review in recommendations section (P1 fix priority).

Secrets stored in inventory.json must be gitignored and managed externally (Vault, AWS Secrets Manager, or your team's secret management solution). Rotation requires edit → redeploy workflow documented above.

---

## Glossary

| Term | Meaning |
|------|---------|
| VLESSReality | XRay protocol with TLS/REALITY encryption for evasive traffic |
| adguard.work/* | Directory for AdGuard runtime state (filter lists, query cache) - never touched by deploy |
| .deployed.sha256 | Marker file tracking last successful deployment signature |
| rollback.tgz | Tarball of previous state available if current deploy fails |

---

## Quick Commands Reference

```bash
# Deploy all nodes
SSH_KEY=~/.ssh/my_key_name ./deploy_nodes.sh all

# Deploy one node
SSH_KEY=~/.ssh/my_key_name ./deploy_nodes.sh <node-name>

# Redeploy after inventory change (ignore signature skip)
# Force update by touching marker or modifying staged files

# Remove a specific node (stats branch tool)
./remove-node/remove_node.sh <id>

# View XRay logs for debugging on remote
ssh <$SSH_USER>@<host> "docker logs xray --tail 50"

# Verify stats endpoint works
curl -k https://<node-host>:<direct_port>/stats
```

---

**Version:** 2.0  
**Author:** Platform Engineering Team  
**License:** MIT (code), proprietary config schema
