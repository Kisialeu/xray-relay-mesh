#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"

INVENTORY="${1:-$MESH_DIR/inventory.json}"
LOCAL_PORT="${STATS_LOCAL_PORT:-8088}"

mesh_check_local_deps
inv_validate "$INVENTORY" || exit 1

MASTER_NODE="$(inv_stats_master_node "$INVENTORY")"
[ -n "$MASTER_NODE" ] || { error "stats.master_node is required"; exit 1; }
inv_node_exists "$INVENTORY" "$MASTER_NODE" || { error "stats.master_node not found: $MASTER_NODE"; exit 1; }

HOST="$(inv_node_field "$INVENTORY" "$MASTER_NODE" host)"
REMOTE_PORT="$(inv_stats_web_port "$INVENTORY")"
TOKEN="$(inv_stats_token "$INVENTORY")"

mesh_resolve_ssh "$INVENTORY" "$MASTER_NODE"

url="http://127.0.0.1:${LOCAL_PORT}/?token=${TOKEN}"
info "Opening SSH tunnel to stats master ${MASTER_NODE} (${HOST})"
info "Open: ${url}"
info "Press Ctrl-C to close the tunnel"

# shellcheck disable=SC2046
exec ssh $(mesh_ssh_opt) -N -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" "$SSH_USER@$HOST"
