#!/usr/bin/env bash
# Syncs already-generated subscription files (from SUB_DIR) to the Caddy
# host (inventory.json's "subs.caddy_host") and reloads it. Run
# subs/generate_subscriptions.sh first - this script does not
# render/regenerate anything, only pushes what's already in SUB_DIR.
# Mirrors the sync_and_start_caddy step in the old deploy.sh.
#
# Usage: relay-mesh/subs/sync_subscriptions.sh [inventory.json]
#
# Optional env:
#   SUB_DIR    - local subscription files dir (default: ./var/subscriptions)
#   SSH_KEY, SSH_USER - override inventory.json's subs.ssh_key/subs.ssh_user

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../../lib/inventory.sh"
# shellcheck source=../../lib/stage.sh
source "$SCRIPT_DIR/../../lib/stage.sh"
# shellcheck source=../../lib/remote.sh
source "$SCRIPT_DIR/../../lib/remote.sh"
# shellcheck source=../../lib/compose.sh
source "$SCRIPT_DIR/../../lib/compose.sh"
# shellcheck source=lib/subs_sync.sh
source "$SCRIPT_DIR/sync.sh"

INVENTORY="${1:-$MESH_DIR/configs/inventory.json}"
SUB_DIR="${SUB_DIR:-$MESH_DIR/var/subscriptions}"

mesh_check_local_deps
inv_validate "$INVENTORY" || exit 1

CADDY_HOST="$(inv_subs_caddy_host "$INVENTORY")"
[ -n "$CADDY_HOST" ] || { error "subs.caddy_host not set in $INVENTORY"; exit 1; }
mesh_validate_deploy_dir "$(inv_subs_caddy_deploy_dir "$INVENTORY")" || exit 1
mesh_validate_deploy_dir "$(inv_subs_content_deploy_dir "$INVENTORY")" || exit 1
mesh_resolve_subs_ssh "$INVENTORY"

if [ ! -d "$SUB_DIR" ] || [ -z "$(ls -A "$SUB_DIR" 2>/dev/null)" ]; then
    error "$SUB_DIR is empty or missing - run subs/generate_subscriptions.sh first"
    exit 1
fi

sync_subs_to_caddy "$INVENTORY" "$SUB_DIR"
