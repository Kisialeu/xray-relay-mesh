#!/usr/bin/env bash
# Compatibility wrapper for managed relay rollback.
#
# Usage: relay-mesh/relay/rollback_mesh.sh <node_name> [inventory.json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"
# shellcheck source=../components/relay/deploy.sh
source "$SCRIPT_DIR/../components/relay/deploy.sh"

usage() { echo "Usage: $0 <node_name> [inventory.json]" >&2; exit 1; }
[ $# -ge 1 ] || usage

NODE="$1"
INVENTORY="${2:-$MESH_DIR/inventory.json}"
mesh_validate_deploy_dir "$RELAY_DEPLOY_DIR" || exit 1

relay_rollback_one "$INVENTORY" "$NODE"
