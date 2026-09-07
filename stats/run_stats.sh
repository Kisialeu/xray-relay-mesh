#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export INVENTORY="${1:-${INVENTORY:-$MESH_DIR/inventory.json}}"
export STATS_DB="${STATS_DB:-$MESH_DIR/stats/stats.sqlite3}"
export PYTHONPATH="$SCRIPT_DIR/src"

exec python3 -m __main__
