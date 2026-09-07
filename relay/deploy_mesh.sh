#!/usr/bin/env bash
# Compatibility wrapper for the managed relay component deployment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"
# shellcheck source=../components/relay/deploy.sh
source "$SCRIPT_DIR/../components/relay/deploy.sh"

usage() { echo "Usage: $0 <all|node_name> [inventory.json]" >&2; exit 1; }
[ $# -ge 1 ] || usage

relay_deploy_target "${2:-$MESH_DIR/inventory.json}" "$1"
