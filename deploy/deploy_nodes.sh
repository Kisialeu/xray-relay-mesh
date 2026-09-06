#!/usr/bin/env bash
# Renders the Xray stack (.env, config.json, AdGuard Home
# config, docker-compose.yml) for one or all nodes from inventory.json,
# uploads it, and starts/reloads it idempotently. Run this BEFORE
# relay-mesh/relay/deploy_mesh.sh - the relay mesh proxies to these nodes'
# direct ports, so they need to be up first.
#
# Usage: relay-mesh/deploy/deploy_nodes.sh <all|node_name> [inventory.json]
#
# Env:
#   SSH_KEY                - forces the same key for every node (else each
#                            node's own required "ssh_key" from inventory.json)
#   SSH_USER               - forces the same user for every node (else each
#                            node's own required "ssh_user" from inventory.json)
#   XRAY_DEPLOY_DIR        - remote deploy dir (default: /opt/xray-node)
#   MESH_WEBHOOK_URL       - optional alert webhook on failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$SCRIPT_DIR/assets"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"
# shellcheck source=lib/xray_render.sh
source "$SCRIPT_DIR/lib/xray_render.sh"
# shellcheck source=lib/xray_ctl.sh
source "$SCRIPT_DIR/lib/xray_ctl.sh"

usage() { echo "Usage: $0 <all|node_name> [inventory.json]" >&2; exit 1; }
[ $# -ge 1 ] || usage

TARGET="$1"
INVENTORY="${2:-$MESH_DIR/inventory.json}"

# Reality keys/users are identical on every node (see inventory.json "xray"
# block). Generate once locally and persist back into the inventory if
# they're missing, so every subsequent deploy (and every node) uses the same
# keys without any per-server generation step.
generate_reality_keys_if_missing() {
    local file="$1"
    inv_xray_has_reality_keys "$file" && return 0

    info "No Reality keys in inventory - generating (requires local docker)..."
    command -v docker >/dev/null 2>&1 \
        || { error "docker required locally to generate Reality keys (or set xray.reality.private_key/public_key manually)"; return 1; }

    local keys priv pub
    keys=$(docker run --rm teddysun/xray:latest xray x25519 2>/dev/null)
    priv=$(echo "$keys" | grep "Private key" | awk '{print $3}')
    pub=$(echo "$keys" | grep "Public key" | awk '{print $3}')
    if [ -z "$priv" ] || [ -z "$pub" ]; then
        error "failed to generate Reality keys"
        return 1
    fi

    inv_xray_set_reality_keys "$file" "$priv" "$pub"
    success "Generated and persisted new Reality keys to $file"
}

deploy_one() {
    local name="$1" host stage rc=0
    host=$(inv_node_field "$INVENTORY" "$name" host)
    if [ -z "$host" ] || [ "$host" = "null" ]; then
        error "no host for node '$name'"
        return 1
    fi

    mesh_resolve_ssh "$INVENTORY" "$name"

    stage="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$stage'" RETURN

    mkdir -p "$stage/config" "$stage/adguard/conf"
    render_xray_env "$INVENTORY" "$name" > "$stage/.env"
    render_xray_config_json "$INVENTORY" "$name" > "$stage/config/config.json"
    render_adguard_yaml "$INVENTORY" > "$stage/adguard/conf/AdGuardHome.yaml"
    cp "$ASSETS_DIR/entrypoint.sh" "$stage/entrypoint.sh"
    cp "$ASSETS_DIR/stats.py" "$stage/stats.py"
    cp "$ASSETS_DIR/docker-compose.xray.yml" "$stage/docker-compose.yml"

    info "$name ($host): preparing host"
    xray_check_docker "$host" || rc=1
    xray_check_docker_compose "$host" || rc=1
    xray_check_remote_deps "$host"
    xray_check_bbr "$host"

    if [ "$rc" -eq 0 ]; then
        xray_apply "$host" "$XRAY_DEPLOY_DIR" "$stage" || rc=1
        xray_install_system_files "$host" "$ASSETS_DIR/xray-logrotate.conf" || true
    fi

    if [ "$rc" -ne 0 ]; then
        alert "xray deploy FAILED for $name ($host) - see log above"
    fi
    return "$rc"
}

mesh_check_local_deps
inv_validate "$INVENTORY" || exit 1
generate_reality_keys_if_missing "$INVENTORY" || exit 1

FAILED=0
if [ "$TARGET" = "all" ]; then
    for name in $(inv_node_names "$INVENTORY"); do
        deploy_one "$name" || FAILED=1
    done
else
    if ! inv_node_exists "$INVENTORY" "$TARGET"; then
        error "node '$TARGET' not found in inventory: $INVENTORY"
        exit 1
    fi
    deploy_one "$TARGET" || FAILED=1
fi

exit "$FAILED"
