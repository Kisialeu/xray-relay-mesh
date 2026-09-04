#!/usr/bin/env bash
# Removes the Xray and HAProxy deployment from one remote node.
# Deliberately does NOT modify inventory.json; use remove-node separately
# when the node should also disappear from the mesh topology.
#
# Usage:
#   relay-mesh/prune-node/prune_node.sh <node_name> [inventory.json] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/inventory.sh"

usage() {
    echo "Usage: $0 <node_name> [inventory.json] [--dry-run]" >&2
    exit 1
}

[ $# -ge 1 ] || usage

NODE="$1"
shift
INVENTORY="$MESH_DIR/inventory.json"
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*) usage ;;
        *) [ -n "$arg" ] && INVENTORY="$arg" ;;
    esac
done

mesh_check_local_deps
inv_validate "$INVENTORY" || exit 1

if ! inv_node_exists "$INVENTORY" "$NODE"; then
    error "node '$NODE' not found in inventory: $INVENTORY"
    exit 1
fi

mesh_resolve_ssh "$INVENTORY" "$NODE"
HOST="$(inv_node_field "$INVENTORY" "$NODE" host)"

XRAY_DIR="${XRAY_DEPLOY_DIR:-/opt/xray-node}"
RELAY_DIR="${RELAY_DEPLOY_DIR:-/opt/relay-node}"

echo "Node:      $NODE ($HOST)"
echo "Inventory: $INVENTORY (will not be modified)"
echo "Prune:     $XRAY_DIR, $RELAY_DIR, Xray system hooks and known containers"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run: no remote changes made."
    exit 0
fi

echo ""
echo "This will stop and delete the Xray and HAProxy deployment on $HOST."
echo "The inventory entry will remain unchanged."
read -r -p "Type '$NODE' to confirm: " confirmation
[ "$confirmation" = "$NODE" ] || { echo "Aborted."; exit 0; }

info "$NODE ($HOST): stopping deployment containers"
ssh_run "$HOST" "
    set -u
    if [ -f '$XRAY_DIR/docker-compose.yml' ]; then
        cd '$XRAY_DIR' && sudo docker compose -f docker-compose.yml down --remove-orphans --volumes || true
    fi
    if [ -f '$RELAY_DIR/docker-compose.yml' ]; then
        cd '$RELAY_DIR' && sudo docker compose -f docker-compose.yml down --remove-orphans --volumes || true
    fi
    sudo docker rm -f xray warp adguard-home xray-relay 2>/dev/null || true
    sudo docker system prune --all --force 2>/dev/null || true
"

info "$NODE ($HOST): removing deployment files, logs, and Xray system hooks"
ssh_run "$HOST" "
    set -u
    sudo rm -rf '$XRAY_DIR' '$RELAY_DIR'
    sudo rm -f /etc/logrotate.d/xray /etc/cron.d/xray-restart /var/log/xray-restart.log
"

success "$NODE ($HOST): Xray and HAProxy deployment pruned"
echo "Inventory unchanged: $INVENTORY"
echo "The node can be deployed again with:"
echo "  ./mesh.sh deploy-node $NODE"
echo "  ./mesh.sh deploy-relay $NODE"
