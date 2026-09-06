#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"

INVENTORY="${1:-$MESH_DIR/inventory.json}"
STATS_DEPLOY_DIR="${STATS_DEPLOY_DIR:-/opt/xray-stats}"

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
    ssh_run "$master_host" "
        set -e
        sudo install -d -m 755 '$key_dir'
        sudo rm -f '$next_key_path' '$next_pub_path'
        sudo ssh-keygen -q -t ed25519 -N '' -f '$next_key_path'
        sudo chmod 600 '$next_key_path'
        sudo chmod 644 '$next_pub_path'
        sudo touch '$known_hosts'
        sudo chmod 644 '$known_hosts'
        sudo chown -R 10001:10001 '$key_dir'
    "
    pub="$(ssh_run "$master_host" "sudo cat '$next_pub_path'")"
    [ -n "$pub" ] || { error "failed to read generated stats SSH public key"; return 1; }

    wrapper='#!/bin/sh
set -eu
case "${SSH_ORIGINAL_COMMAND:-}" in
    stats) exec curl -fsS --max-time 5 http://127.0.0.1:9091/stats ;;
    online) exec curl -fsS --max-time 5 http://127.0.0.1:9091/online ;;
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
        ssh_run "$host" "
            set -e
            if ! id '$SSH_USER_STATS' >/dev/null 2>&1; then
                sudo useradd --system --create-home --shell /bin/sh '$SSH_USER_STATS'
            fi
            sudo usermod --shell /bin/sh '$SSH_USER_STATS'
            command -v curl >/dev/null 2>&1
            sudo install -d -m 700 -o '$SSH_USER_STATS' -g '$SSH_USER_STATS' \"\$(getent passwd '$SSH_USER_STATS' | cut -d: -f6)/.ssh\"
            sudo install -m 755 /dev/null /usr/local/sbin/xray-stats-poller
            printf '%s' '$wrapper_b64' | base64 -d | sudo tee /usr/local/sbin/xray-stats-poller >/dev/null
            sudo chmod 755 /usr/local/sbin/xray-stats-poller
            auth=\"\$(getent passwd '$SSH_USER_STATS' | cut -d: -f6)/.ssh/authorized_keys\"
            sudo touch \"\$auth\"
            sudo chmod 600 \"\$auth\"
            if ! printf '%s' '$key_b64' | base64 -d | sudo grep -Fqx -f - \"\$auth\"; then
                printf '%s' '$key_b64' | base64 -d | sudo tee -a \"\$auth\" >/dev/null
            fi
            sudo chown -R '$SSH_USER_STATS':'$SSH_USER_STATS' \"\$(dirname \"\$auth\")\"
        "
        if ! ssh-keygen -F "$host" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
            host_keys="$(ssh-keyscan -T 5 -p "$SSH_PORT_STATS" -H "$host" 2>/dev/null || true)"
        else
            host_keys="$(ssh-keygen -F "$host" -f "$HOME/.ssh/known_hosts" 2>/dev/null | awk 'NF == 3 {print $1, $2, $3}')"
        fi
        if [ -z "$host_keys" ]; then
            host_keys="$(ssh_run "$master_host" "ssh-keyscan -T 5 -p '$SSH_PORT_STATS' -H '$host' 2>/dev/null" || true)"
        fi
        [ -n "$host_keys" ] || {
            error "$name ($host): unable to collect SSH host key from deployment host or master"
            return 1
        }
        host_keys_b64="$(printf '%s\n' "$host_keys" | base64 | tr -d '\n')"
        ssh_run "$master_host" "
            if ! sudo ssh-keygen -F '$host' -f '$known_hosts' >/dev/null 2>&1; then
                printf '%s' '$host_keys_b64' | base64 -d | sudo tee -a '$known_hosts' >/dev/null
            fi
        "
    done < <(jq -r '.nodes[] | [.name, .host] | @tsv' "$INVENTORY")
    ssh_run "$master_host" "
        set -e
        sudo mv '$next_key_path' '$key_path'
        sudo mv '$next_pub_path' '$pub_path'
        sudo chmod 600 '$key_path'
        sudo chmod 644 '$pub_path'
        sudo chown 10001:10001 '$key_path' '$pub_path'
    "
    NEW_STATS_PUB="$pub"
}

cleanup_old_stats_keys() {
    local master_host="$1" pub="$2" key_line key_b64
    key_line="$(printf 'command=\"/usr/local/sbin/xray-stats-poller\",restrict %s xray-stats-poller\n' "$pub")"
    key_b64="$(printf '%s' "$key_line" | base64 | tr -d '\n')"
    while read -r name host; do
        [ "$name" = "$MASTER_NODE" ] && continue
        mesh_resolve_ssh "$INVENTORY" "$name"
        ssh_run "$host" "
            auth=\"\$(getent passwd '$SSH_USER_STATS' | cut -d: -f6)/.ssh/authorized_keys\"
            sudo sed -i '/xray-stats-poller/d' \"\$auth\"
            printf '%s' '$key_b64' | base64 -d | sudo tee -a \"\$auth\" >/dev/null
        "
    done < <(jq -r '.nodes[] | [.name, .host] | @tsv' "$INVENTORY")
}

bootstrap_ssh_polling "$HOST"

stage="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$stage'" EXIT

cp -r "$SCRIPT_DIR/src" "$stage/src"
cp "$SCRIPT_DIR/requirements.txt" "$stage/requirements.txt"
cp "$SCRIPT_DIR/Dockerfile" "$stage/Dockerfile"
cp "$SCRIPT_DIR/.dockerignore" "$stage/.dockerignore"
cp "$SCRIPT_DIR/docker-compose.stats.yml" "$stage/docker-compose.yml"
jq '{
    stats: {
        master_node: .stats.master_node,
        node_port: (.stats.node_port // 9091)
    },
    nodes: [.nodes[] | {
        name,
        friendly_name,
        host,
        stats_host
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
ssh_run "$HOST" "sudo install -d -m 700 -o 70 -g 70 '$STATS_DEPLOY_DIR/postgres'"
ssh_run "$HOST" "sudo chmod 600 '$STATS_DEPLOY_DIR/.env' && cd '$STATS_DEPLOY_DIR' && docker compose up -d --build --wait --wait-timeout 120"
cleanup_old_stats_keys "$HOST" "$NEW_STATS_PUB"
success "$HOST: central stats service deployed"
