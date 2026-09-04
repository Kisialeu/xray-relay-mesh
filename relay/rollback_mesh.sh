#!/usr/bin/env bash
# Restores config/haproxy.cfg.last-good on one node and reloads.
# Use when a bad deploy needs to be undone manually.
#
# Usage: relay-mesh/relay/rollback_mesh.sh <node_name> [inventory.json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"
# shellcheck source=lib/haproxy_ctl.sh
source "$SCRIPT_DIR/lib/haproxy_ctl.sh"

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

mesh_resolve_ssh "$INVENTORY" "$NODE"

HOST=$(inv_node_field "$INVENTORY" "$NODE" host)
if [ -z "$HOST" ] || [ "$HOST" = "null" ]; then
    error "no host for node '$NODE'"
    exit 1
fi

haproxy_rollback "$HOST" "$RELAY_DEPLOY_DIR"
