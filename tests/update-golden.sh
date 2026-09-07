#!/usr/bin/env bash
# Render deterministic fixtures. With one argument, refresh tests/golden.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${1:?inventory path required}"
OUT_DIR="${2:-$ROOT_DIR/tests/golden/$(basename "$INVENTORY" .json)}"

# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$ROOT_DIR/lib/inventory.sh"
# shellcheck source=../relay/lib/render.sh
source "$ROOT_DIR/relay/lib/render.sh"
# shellcheck source=../deploy/lib/xray_render.sh
source "$ROOT_DIR/deploy/lib/xray_render.sh"
# shellcheck source=../deploy/lib/hysteria_render.sh
source "$ROOT_DIR/deploy/lib/hysteria_render.sh"

inv_validate "$INVENTORY"
mkdir -p "$OUT_DIR"

while IFS= read -r node; do
    node_dir="$OUT_DIR/$node"
    mkdir -p "$node_dir"
    render_haproxy_cfg "$INVENTORY" "$node" > "$node_dir/haproxy.cfg"
    render_xray_env "$INVENTORY" "$node" > "$node_dir/xray.env"
    render_hysteria_env "$INVENTORY" "$node" >> "$node_dir/xray.env"
    render_xray_config_json "$INVENTORY" "$node" > "$node_dir/xray.json"
    render_adguard_yaml "$INVENTORY" > "$node_dir/adguard.yaml"
    if [ "$(inv_node_has_hysteria "$INVENTORY" "$node")" = "true" ]; then
        render_hysteria_config "$INVENTORY" "$node" > "$node_dir/hysteria.yaml"
    fi
done < <(inv_node_names "$INVENTORY")
