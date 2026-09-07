#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../../lib/inventory.sh"

SERVICE_DIR="$MESH_DIR/services/stats"

INVENTORY="${1:-$MESH_DIR/configs/inventory.json}"
STATS_DEPLOY_DIR="${STATS_DEPLOY_DIR:-/opt/xray-stats}"
mesh_validate_deploy_dir "$STATS_DEPLOY_DIR" || exit 1

mesh_check_local_deps
inv_validate "$INVENTORY" || exit 1

MASTER_NODE="$(inv_stats_master_node "$INVENTORY")"
[ -n "$MASTER_NODE" ] || { error "stats.master_node is required"; exit 1; }
inv_node_exists "$INVENTORY" "$MASTER_NODE" || { error "stats.master_node not found: $MASTER_NODE"; exit 1; }

HOST="$(inv_node_field "$INVENTORY" "$MASTER_NODE" host)"
POSTGRES_PASSWORD="$(inv_stats_postgres_password "$INVENTORY")"
STATS_TOKEN="$(inv_stats_token "$INVENTORY")"
POSTGRES_PORT="$(inv_stats_postgres_port "$INVENTORY")"
WEB_PORT="$(inv_stats_web_port "$INVENTORY")"
APP_PORT="${STATS_APP_PORT:-$(inv_stats_app_port "$INVENTORY")}"
SSH_USER_STATS="$(jq -r '.stats.ssh_user // "stats-poller"' "$INVENTORY")"
SSH_PORT_STATS="$(jq -r '.stats.ssh_port // 22' "$INVENTORY")"
POLL_INTERVAL_VALUE="${STATS_POLL_INTERVAL:-15}"
HTTP_TIMEOUT_VALUE="${STATS_HTTP_TIMEOUT:-5}"
RETENTION_DAYS_VALUE="${STATS_RETENTION_DAYS:-90}"
ONLINE_WINDOW_VALUE="${STATS_ONLINE_WINDOW:-120}"
ACTIVE_DURATION_VALUE="${STATS_ACTIVE_DURATION:-30}"
MIN_ACTIVITY_BYTES_VALUE="${STATS_MIN_ACTIVITY_BYTES:-1024}"

[ -n "$POSTGRES_PASSWORD" ] || { error "stats.postgres_password is required"; exit 1; }
[ -n "$STATS_TOKEN" ] || { error "stats.token is required"; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ && "$APP_PORT" -ge 1 && "$APP_PORT" -le 65535 ]] \
    || { error "STATS_APP_PORT must be a port in range 1-65535"; exit 1; }
[ "$APP_PORT" != "$WEB_PORT" ] || { error "stats.app_port and stats.web_port must differ"; exit 1; }
for value in "$POLL_INTERVAL_VALUE" "$RETENTION_DAYS_VALUE" "$ONLINE_WINDOW_VALUE" "$ACTIVE_DURATION_VALUE" "$MIN_ACTIVITY_BYTES_VALUE"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { error "stats timing and activity values must be positive integers"; exit 1; }
done
[ "$RETENTION_DAYS_VALUE" -le 90 ] || { error "STATS_RETENTION_DAYS must not exceed 90"; exit 1; }
[[ "$HTTP_TIMEOUT_VALUE" =~ ^([1-9][0-9]*|0[.][0-9]*[1-9][0-9]*|[1-9][0-9]*[.][0-9]+)$ ]] \
    || { error "STATS_HTTP_TIMEOUT must be a positive number"; exit 1; }

mesh_resolve_ssh "$INVENTORY" "$MASTER_NODE"

bootstrap_ssh_polling() {
    local master_host="$1"
    local key_dir="$STATS_DEPLOY_DIR/ssh"
    local key_path="$key_dir/id_ed25519"
    local pub_path="$key_path.pub"
    local next_key_path="$key_dir/id_ed25519.next"
    local next_pub_path="$next_key_path.pub"
    local known_hosts="$key_dir/known_hosts"
    local pub key_line wrapper wrapper_b64 key_b64

    info "$MASTER_NODE ($master_host): preparing SSH polling key"
    remote_bash "$master_host" "$key_dir" "$next_key_path" "$next_pub_path" "$known_hosts" <<'REMOTE'
set -euo pipefail
sudo install -d -m 0755 "$1"
sudo rm -f -- "$2" "$3"
sudo ssh-keygen -q -t ed25519 -N '' -f "$2"
sudo chmod 0600 "$2"
sudo chmod 0644 "$3"
sudo touch "$4"
sudo chmod 0644 "$4"
sudo chown -R 10001:10001 "$1"
REMOTE
    pub="$(remote_bash "$master_host" "$next_pub_path" <<'REMOTE'
sudo cat "$1"
REMOTE
    )"
    [ -n "$pub" ] || { error "failed to read generated stats SSH public key"; return 1; }

    # Explicit allowlist by design (never a dynamic/open pass-through over
    # SSH) - adding a future protocol means adding two more case lines here
    # to match its two new entries in deploy/assets/stats.py's PROTOCOLS
    # dict, nothing else about this forced-command mechanism changes.
    wrapper='#!/bin/sh
set -eu
case "${SSH_ORIGINAL_COMMAND:-}" in
    xray:stats) exec curl -fsS --max-time 5 http://127.0.0.1:9091/xray/stats ;;
    xray:online) exec curl -fsS --max-time 5 http://127.0.0.1:9091/xray/online ;;
    hysteria:stats) exec curl -fsS --max-time 5 http://127.0.0.1:9091/hysteria/stats ;;
    hysteria:online) exec curl -fsS --max-time 5 http://127.0.0.1:9091/hysteria/online ;;
    *) exit 126 ;;
esac
'
    wrapper_b64="$(printf '%s' "$wrapper" | base64 | tr -d '\n')"
    key_line="$(printf 'command=\"/usr/local/sbin/xray-stats-poller\",restrict %s xray-stats-poller\n' "$pub")"
    key_b64="$(printf '%s' "$key_line" | base64 | tr -d '\n')"

    while read -r name host; do
        [ "$name" = "$MASTER_NODE" ] && continue
        mesh_resolve_ssh "$INVENTORY" "$name"
        info "$name ($host): installing restricted stats-poller key"
        remote_bash "$host" "$SSH_USER_STATS" "$wrapper_b64" "$key_b64" <<'REMOTE'
set -euo pipefail
stats_user=$1
wrapper_b64=$2
key_b64=$3
if ! id "$stats_user" >/dev/null 2>&1; then
    sudo useradd --system --create-home --shell /bin/sh "$stats_user"
fi
sudo usermod --shell /bin/sh "$stats_user"
command -v curl >/dev/null 2>&1
home_dir=$(getent passwd "$stats_user" | cut -d: -f6)
sudo install -d -m 0700 -o "$stats_user" -g "$stats_user" "$home_dir/.ssh"
printf '%s' "$wrapper_b64" | base64 -d | sudo tee /usr/local/sbin/xray-stats-poller >/dev/null
sudo chmod 0755 /usr/local/sbin/xray-stats-poller
auth="$home_dir/.ssh/authorized_keys"
sudo touch "$auth"
sudo chmod 0600 "$auth"
if ! printf '%s' "$key_b64" | base64 -d | sudo grep -Fqx -f - "$auth"; then
    printf '%s' "$key_b64" | base64 -d | sudo tee -a "$auth" >/dev/null
fi
sudo chown -R "$stats_user:$stats_user" "$home_dir/.ssh"
REMOTE
        if ! ssh-keygen -F "$host" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
            host_keys="$(ssh-keyscan -T 5 -p "$SSH_PORT_STATS" -H "$host" 2>/dev/null || true)"
        else
            host_keys="$(ssh-keygen -F "$host" -f "$HOME/.ssh/known_hosts" 2>/dev/null | awk 'NF == 3 {print $1, $2, $3}')"
        fi
        if [ -z "$host_keys" ]; then
            mesh_resolve_ssh "$INVENTORY" "$MASTER_NODE"
            host_keys="$(remote_bash "$master_host" "$SSH_PORT_STATS" "$host" <<'REMOTE' || true
ssh-keyscan -T 5 -p "$1" -H "$2" 2>/dev/null
REMOTE
            )"
        fi
        [ -n "$host_keys" ] || {
            error "$name ($host): unable to collect SSH host key from deployment host or master"
            return 1
        }
        host_keys_b64="$(printf '%s\n' "$host_keys" | base64 | tr -d '\n')"
        mesh_resolve_ssh "$INVENTORY" "$MASTER_NODE"
        remote_bash "$master_host" "$host" "$known_hosts" "$host_keys_b64" <<'REMOTE'
if ! sudo ssh-keygen -F "$1" -f "$2" >/dev/null 2>&1; then
    printf '%s' "$3" | base64 -d | sudo tee -a "$2" >/dev/null
fi
REMOTE
    done < <(jq -r '.nodes[] | [.name, .host] | @tsv' "$INVENTORY")
    mesh_resolve_ssh "$INVENTORY" "$MASTER_NODE"
    remote_bash "$master_host" "$next_key_path" "$key_path" "$next_pub_path" "$pub_path" <<'REMOTE'
set -euo pipefail
sudo mv "$1" "$2"
sudo mv "$3" "$4"
sudo chmod 0600 "$2"
sudo chmod 0644 "$4"
sudo chown 10001:10001 "$2" "$4"
REMOTE
    NEW_STATS_PUB="$pub"
}

cleanup_old_stats_keys() {
    local master_host="$1" pub="$2" key_line key_b64
    key_line="$(printf 'command=\"/usr/local/sbin/xray-stats-poller\",restrict %s xray-stats-poller\n' "$pub")"
    key_b64="$(printf '%s' "$key_line" | base64 | tr -d '\n')"
    while read -r name host; do
        [ "$name" = "$MASTER_NODE" ] && continue
        mesh_resolve_ssh "$INVENTORY" "$name"
        remote_bash "$host" "$SSH_USER_STATS" "$key_b64" <<'REMOTE'
set -euo pipefail
auth="$(getent passwd "$1" | cut -d: -f6)/.ssh/authorized_keys"
sudo sed -i '/xray-stats-poller/d' "$auth"
printf '%s' "$2" | base64 -d | sudo tee -a "$auth" >/dev/null
REMOTE
    done < <(jq -r '.nodes[] | [.name, .host] | @tsv' "$INVENTORY")
}

bootstrap_ssh_polling "$HOST"

stage="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$stage'" EXIT

cp -r "$SERVICE_DIR/src" "$stage/src"
cp "$SERVICE_DIR/requirements.txt" "$stage/requirements.txt"
cp "$SERVICE_DIR/Dockerfile" "$stage/Dockerfile"
cp "$SERVICE_DIR/.dockerignore" "$stage/.dockerignore"
cp "$SERVICE_DIR/docker-compose.stats.yml" "$stage/docker-compose.yml"
jq '{
    stats: {
        master_node: .stats.master_node,
        node_port: (.stats.node_port // 9091)
    },
    nodes: [.nodes[] | {
        name,
        friendly_name,
        host,
        stats_host,
        protocols: (.protocols // ["xray"])
    } | with_entries(select(.value != null))]
}' "$INVENTORY" > "$stage/inventory.json"

{
    printf 'POSTGRES_DB=xray_stats\n'
    printf 'POSTGRES_USER=xray_stats\n'
    printf 'POSTGRES_PASSWORD=%s\n' "$POSTGRES_PASSWORD"
    printf 'STATS_POSTGRES_PORT=%s\n' "$POSTGRES_PORT"
    printf 'STATS_APP_PORT=%s\n' "$APP_PORT"
    printf 'STATS_API_TOKEN=%s\n' "$STATS_TOKEN"
    printf 'STATS_BIND=127.0.0.1\n'
    printf 'STATS_POLL_INTERVAL=%s\n' "$POLL_INTERVAL_VALUE"
    printf 'STATS_HTTP_TIMEOUT=%s\n' "$HTTP_TIMEOUT_VALUE"
    printf 'STATS_RETENTION_DAYS=%s\n' "$RETENTION_DAYS_VALUE"
    printf 'STATS_ONLINE_WINDOW=%s\n' "$ONLINE_WINDOW_VALUE"
    printf 'STATS_ACTIVE_DURATION=%s\n' "$ACTIVE_DURATION_VALUE"
    printf 'STATS_MIN_ACTIVITY_BYTES=%s\n' "$MIN_ACTIVITY_BYTES_VALUE"
    printf 'STATS_SSH_USER=%s\n' "$SSH_USER_STATS"
    printf 'STATS_SSH_PORT=%s\n' "$SSH_PORT_STATS"
} > "$stage/.env"
chmod 600 "$stage/.env"

info "$MASTER_NODE ($HOST): deploying central stats service"
mesh_check_docker "$HOST"
mesh_check_docker_compose "$HOST"
mesh_upload_dir_merge "$HOST" "$stage" "$STATS_DEPLOY_DIR"
mesh_resolve_ssh "$INVENTORY" "$MASTER_NODE"
remote_bash "$HOST" "$STATS_DEPLOY_DIR" <<'REMOTE'
set -euo pipefail
sudo install -d -m 0700 -o 70 -g 70 "$1/postgres"
sudo chmod 0600 "$1/.env"
cd "$1"
docker compose up -d --build --wait --wait-timeout 120
REMOTE
cleanup_old_stats_keys "$HOST" "$NEW_STATS_PUB"
success "$HOST: central stats service deployed"
