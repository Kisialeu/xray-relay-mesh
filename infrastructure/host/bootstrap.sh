#!/usr/bin/env bash
# Explicitly install and configure deployment prerequisites on one node.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../../bashbuild/lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../../bashbuild/lib/inventory.sh"
# shellcheck source=../lib/deps.sh
source "$SCRIPT_DIR/../../bashbuild/lib/deps.sh"

usage() { echo "Usage: $0 <node_name> [inventory.json]" >&2; exit 1; }
[ $# -ge 1 ] || usage

NODE="$1"
INVENTORY="${2:-$MESH_DIR/configs/inventory.json}"

mesh_check_local_deps
inv_validate "$INVENTORY"
inv_node_exists "$INVENTORY" "$NODE" \
    || { error "node '$NODE' not found in inventory: $INVENTORY"; exit 1; }

mesh_resolve_ssh "$INVENTORY" "$NODE"
HOST="$(inv_node_field "$INVENTORY" "$NODE" host)"
HYSTERIA_ENABLED="$(inv_node_has_protocol "$INVENTORY" "$NODE" hysteria)"

info "$NODE ($HOST): bootstrapping deployment prerequisites"
mesh_bootstrap_host "$HOST" "$HYSTERIA_ENABLED"
success "$NODE ($HOST): bootstrap completed"
