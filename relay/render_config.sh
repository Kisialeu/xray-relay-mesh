#!/usr/bin/env bash
# Render haproxy.cfg for one mesh node from inventory.json - for local
# testing/dry-run. Does not touch any remote host.
#
# Usage: relay-mesh/relay/render_config.sh <node_name> [inventory.json] [-o out_file]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"
# shellcheck source=lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"

usage() { echo "Usage: $0 <node_name> [inventory.json] [-o out_file]" >&2; exit 1; }

[ $# -ge 1 ] || usage
NODE="$1"; shift

INVENTORY="$MESH_DIR/inventory.json"
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUT="$2"; shift 2 ;;
        *)  INVENTORY="$1"; shift ;;
    esac
done

CFG="$(render_haproxy_cfg "$INVENTORY" "$NODE")"

if [ -n "$OUT" ]; then
    printf '%s\n' "$CFG" > "$OUT"
    success "Rendered $NODE -> $OUT"
else
    printf '%s\n' "$CFG"
fi
