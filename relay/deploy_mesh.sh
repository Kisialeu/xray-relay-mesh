#!/usr/bin/env bash
# Push-model deploy: renders haproxy.cfg for one or all mesh nodes from
# inventory.json, validates remotely, applies idempotently, reloads.
# Adding/removing a node = editing inventory.json only, no per-server edits.
#
# Usage: relay-mesh/relay/deploy_mesh.sh <all|node_name> [inventory.json]
#
# Env:
#   SSH_KEY                - forces the same key for every node (else each
#                            node's own required "ssh_key" from inventory.json)
#   SSH_USER               - forces the same user for every node (else each
#                            node's own required "ssh_user" from inventory.json)
#   RELAY_DEPLOY_DIR       - remote deploy dir (default: /opt/relay-node)
#   MESH_WEBHOOK_URL       - optional alert webhook on failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"
# shellcheck source=lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"
# shellcheck source=lib/haproxy_ctl.sh
source "$SCRIPT_DIR/lib/haproxy_ctl.sh"

usage() { echo "Usage: $0 <all|node_name> [inventory.json]" >&2; exit 1; }
[ $# -ge 1 ] || usage

TARGET="$1"
INVENTORY="${2:-$MESH_DIR/inventory.json}"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.relay.yml"

deploy_one() {
    local name="$1" host tmp_cfg rc=0
    host=$(inv_node_field "$INVENTORY" "$name" host)
    if [ -z "$host" ] || [ "$host" = "null" ]; then
        error "no host for node '$name'"
        return 1
    fi

    mesh_resolve_ssh "$INVENTORY" "$name"

    tmp_cfg="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_cfg'" RETURN

    if ! render_haproxy_cfg "$INVENTORY" "$name" > "$tmp_cfg"; then
        error "$name: render failed"
        return 1
    fi

    info "$name ($host): deploying relay mesh config"
    mesh_check_docker "$host" || rc=1
    mesh_check_docker_compose "$host" || rc=1

    if [ "$rc" -eq 0 ]; then
        haproxy_ensure_compose "$host" "$RELAY_DEPLOY_DIR" "$COMPOSE_FILE" || rc=1
        haproxy_apply "$host" "$RELAY_DEPLOY_DIR" "$tmp_cfg" || rc=1
        if [ "$rc" -eq 0 ] && [ "$(inv_stats_expose_haproxy "$INVENTORY")" = "true" ]; then
            haproxy_apply_stats_firewall \
                "$host" \
                "$(inv_stats_public_port "$INVENTORY")" \
                "$(inv_stats_allowed_sources "$INVENTORY")" || rc=1
            haproxy_check_stats_listener "$host" "$(inv_stats_public_port "$INVENTORY")" || rc=1
        fi
    fi

    if [ "$rc" -ne 0 ]; then
        alert "mesh deploy FAILED for $name ($host) - previous config left in place"
    fi
    return "$rc"
}

mesh_check_local_deps
inv_validate "$INVENTORY" || exit 1

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
