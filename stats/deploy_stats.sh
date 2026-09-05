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

[ -n "$POSTGRES_PASSWORD" ] || { error "stats.postgres_password is required"; exit 1; }
[ -n "$STATS_TOKEN" ] || { error "stats.token is required"; exit 1; }

mesh_resolve_ssh "$INVENTORY" "$MASTER_NODE"

stage="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$stage'" EXIT

cp -r "$SCRIPT_DIR/src" "$stage/src"
cp "$SCRIPT_DIR/requirements.txt" "$stage/requirements.txt"
cp "$SCRIPT_DIR/Dockerfile" "$stage/Dockerfile"
cp "$SCRIPT_DIR/docker-compose.stats.yml" "$stage/docker-compose.yml"
cp "$INVENTORY" "$stage/inventory.json"

{
    printf 'POSTGRES_DB=xray_stats\n'
    printf 'POSTGRES_USER=xray_stats\n'
    printf 'POSTGRES_PASSWORD=%s\n' "$POSTGRES_PASSWORD"
    printf 'STATS_POSTGRES_PORT=%s\n' "$POSTGRES_PORT"
    printf 'STATS_WEB_PORT=%s\n' "$WEB_PORT"
    printf 'STATS_API_TOKEN=%s\n' "$STATS_TOKEN"
    printf 'STATS_NODE_TOKEN=%s\n' "$STATS_TOKEN"
    printf 'STATS_BIND=127.0.0.1\n'
    printf 'STATS_POLL_INTERVAL=15\n'
    printf 'STATS_HTTP_TIMEOUT=5\n'
    printf 'STATS_RETENTION_DAYS=30\n'
} > "$stage/.env"

info "$MASTER_NODE ($HOST): deploying central stats service"
mesh_check_docker "$HOST"
mesh_check_docker_compose "$HOST"
mesh_upload_dir_merge "$HOST" "$stage" "$STATS_DEPLOY_DIR"
ssh_run "$HOST" "cd ${STATS_DEPLOY_DIR} && docker compose up -d --build"
success "$HOST: central stats service deployed"
