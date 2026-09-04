#!/usr/bin/env bash
# Decommission a node: remove it from inventory.json so relay peers stop
# reserving a port for it. Subscription content is NOT patched in place
# here - re-running subs/generate_subscriptions.sh (which rebuilds every
# link from the current inventory) is the correct way to drop the dead
# node's direct link and any relay link routed through/to it, since that
# handles relay ("--via-") links too, not just direct ones matching the
# node's own hostname.
#
# Usage:
#   relay-mesh/remove-node/remove_node.sh <node_name> [inventory.json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"

usage() { echo "Usage: $0 <node_name> [inventory.json]" >&2; exit 1; }
[ $# -ge 1 ] || usage

NODE="$1"
INVENTORY="${2:-$MESH_DIR/inventory.json}"

mesh_check_local_deps
inv_validate "$INVENTORY" || exit 1

if ! inv_node_exists "$INVENTORY" "$NODE"; then
    error "node '$NODE' not found in inventory: $INVENTORY"
    exit 1
fi

DEAD_HOST=$(inv_node_field "$INVENTORY" "$NODE" host)

inv_remove_node "$INVENTORY" "$NODE"
success "'$NODE' ($DEAD_HOST) removed from $INVENTORY"

echo ""
echo "Next steps:"
echo "  1. Push the updated relay config to the remaining nodes so they"
echo "     stop reserving a relay port for '$NODE':"
echo "       relay-mesh/relay/deploy_mesh.sh all $INVENTORY"
echo "  2. Regenerate + sync subscriptions so no user's links still"
echo "     reference '$NODE' (direct or via a relay entry point):"
echo "       relay-mesh/subs/generate_subscriptions.sh $INVENTORY"
echo "       relay-mesh/subs/sync_subscriptions.sh $INVENTORY"
echo ""
echo "The decommissioned server itself (Xray/HAProxy containers, the VM/"
echo "instance) is left untouched - this script only updates bookkeeping."
