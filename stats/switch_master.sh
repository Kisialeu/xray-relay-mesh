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

tmp_inventory="$(mktemp)"
trap 'rm -f "$tmp_inventory"' EXIT
jq --arg master "$NEW_MASTER" '.stats.master_node = $master' "$INVENTORY" > "$tmp_inventory"
inv_validate "$tmp_inventory"

NEW_HOST="$(inv_node_field "$INVENTORY" "$NEW_MASTER" host)"
OLD_HOST="$(inv_node_field "$INVENTORY" "$OLD_MASTER" host)"
info "Deploying new stats master: $NEW_MASTER ($NEW_HOST)"
"$SCRIPT_DIR/deploy_stats.sh" "$tmp_inventory"
"$SCRIPT_DIR/../web/deploy_web.sh" "$tmp_inventory"

mesh_resolve_ssh "$tmp_inventory" "$NEW_MASTER"
mesh_container_running "$NEW_HOST" xray-stats || {
    error "$NEW_MASTER: xray-stats container is not running; keeping current master"
    exit 1
}

mv "$tmp_inventory" "$INVENTORY"
trap - EXIT
success "stats.master_node updated: $OLD_MASTER -> $NEW_MASTER"

mesh_resolve_ssh "$INVENTORY" "$OLD_MASTER"
info "$OLD_MASTER ($OLD_HOST): stopping old stats application"
ssh_run "$OLD_HOST" "cd '$STATS_DEPLOY_DIR' && docker compose stop stats 2>/dev/null || true"
ssh_run "$OLD_HOST" "cd '$WEB_DEPLOY_DIR' && docker compose stop web-app stats-web 2>/dev/null || true"
success "$OLD_MASTER: old stats backend and web stopped; Postgres was left untouched"
