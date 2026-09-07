#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"

NEW_MASTER="${1:-}"
INVENTORY="${2:-$MESH_DIR/inventory.json}"
STATS_DEPLOY_DIR="${STATS_DEPLOY_DIR:-/opt/xray-stats}"
WEB_DEPLOY_DIR="${WEB_DEPLOY_DIR:-/opt/xray-web}"
mesh_validate_deploy_dir "$STATS_DEPLOY_DIR" || exit 1
mesh_validate_deploy_dir "$WEB_DEPLOY_DIR" || exit 1

[ -n "$NEW_MASTER" ] || {
    error "usage: $0 <new-master-node> [inventory.json]"
    exit 1
}

mesh_check_local_deps
inv_validate "$INVENTORY"
inv_node_exists "$INVENTORY" "$NEW_MASTER" || {
    error "stats master node not found in inventory: $NEW_MASTER"
    exit 1
}

OLD_MASTER="$(inv_stats_master_node "$INVENTORY")"
[ -n "$OLD_MASTER" ] || {
    error "current stats.master_node is not configured"
    exit 1
}
[ "$OLD_MASTER" != "$NEW_MASTER" ] || {
    error "new stats master is already the current master: $NEW_MASTER"
    exit 1
}
[ "${STATS_ALLOW_DISCONTINUOUS_HISTORY:-0}" = "1" ] || {
    error "switching masters does not migrate PostgreSQL history"
    error "set STATS_ALLOW_DISCONTINUOUS_HISTORY=1 to confirm this operation"
    exit 1
}

tmp_inventory="$(mktemp "${INVENTORY}.candidate.XXXXXX")"
trap 'rm -f "$tmp_inventory"' EXIT
jq --arg master "$NEW_MASTER" '.stats.master_node = $master' "$INVENTORY" > "$tmp_inventory"
inv_validate "$tmp_inventory"

NEW_HOST="$(inv_node_field "$INVENTORY" "$NEW_MASTER" host)"
OLD_HOST="$(inv_node_field "$INVENTORY" "$OLD_MASTER" host)"
NEW_APP_PORT="$(inv_stats_app_port "$tmp_inventory")"
info "Deploying new stats master: $NEW_MASTER ($NEW_HOST)"
"$SCRIPT_DIR/deploy_stats.sh" "$tmp_inventory"
"$SCRIPT_DIR/../web/deploy_web.sh" "$tmp_inventory"

mesh_resolve_ssh "$tmp_inventory" "$NEW_MASTER"
mesh_container_running "$NEW_HOST" xray-stats || {
    error "$NEW_MASTER: xray-stats container is not running; keeping current master"
    exit 1
}
remote_bash "$NEW_HOST" "$NEW_APP_PORT" <<'REMOTE' || {
curl -fsS --max-time 5 "http://127.0.0.1:$1/api/health" >/dev/null
REMOTE
    error "$NEW_MASTER: stats health check failed; keeping current master"
    exit 1
}

inv_stats_set_master "$INVENTORY" "$NEW_MASTER"
rm -f "$tmp_inventory"
trap - EXIT
success "stats.master_node updated: $OLD_MASTER -> $NEW_MASTER"

mesh_resolve_ssh "$INVENTORY" "$OLD_MASTER"
info "$OLD_MASTER ($OLD_HOST): stopping old stats application"
remote_bash "$OLD_HOST" "$STATS_DEPLOY_DIR" "$WEB_DEPLOY_DIR" <<'REMOTE'
cd "$1" && docker compose stop stats 2>/dev/null || true
cd "$2" && docker compose stop web-app stats-web 2>/dev/null || true
REMOTE
success "$OLD_MASTER: old stats backend and web stopped; Postgres was left untouched"
