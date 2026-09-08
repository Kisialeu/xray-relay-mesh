#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../bashbuild/lib/common.sh"
source "$SCRIPT_DIR/../../bashbuild/lib/inventory.sh"

INVENTORY="${2:-$MESH_DIR/configs/inventory.json}"
NODE="${1:?usage: adguard_ui.sh NODE INVENTORY}"
LOCAL_PORT="${ADGUARD_LOCAL_PORT:-3000}"

mesh_check_local_deps
inv_validate "$INVENTORY" || exit 1
inv_node_exists "$INVENTORY" "$NODE" || { error "node not found: $NODE"; exit 1; }
[[ "$LOCAL_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || { error "ADGUARD_LOCAL_PORT must be a valid TCP port"; exit 1; }

HOST="$(inv_node_field "$INVENTORY" "$NODE" host)"
mesh_resolve_ssh "$INVENTORY" "$NODE"
mesh_build_ssh_args

url="http://127.0.0.1:${LOCAL_PORT}"
info "Opening AdGuard Home UI tunnel for ${NODE} (${HOST})"
info "Open: ${url}"
info "Press Ctrl-C to close the tunnel"

ssh "${MESH_SSH_ARGS[@]}" -N -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:3000" "$SSH_USER@$HOST" &
tunnel_pid=$!
cleanup() {
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

sleep 1
kill -0 "$tunnel_pid" 2>/dev/null || { error "SSH tunnel failed to start"; exit 1; }

case "$(uname -s)" in
    Darwin) open "$url" >/dev/null 2>&1 || warn "browser launch failed; open $url manually" ;;
    Linux) command -v xdg-open >/dev/null 2>&1 && xdg-open "$url" >/dev/null 2>&1 || warn "browser launch unavailable; open $url manually" ;;
    *) warn "browser launch unsupported; open $url manually" ;;
esac

wait "$tunnel_pid"
