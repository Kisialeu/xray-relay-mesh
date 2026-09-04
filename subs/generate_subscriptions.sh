#!/usr/bin/env bash
# Generates per-user subscription files (direct + curated relay links) from
# inventory.json, in the same format the existing Caddy pipeline serves.
# Writes to SUB_DIR ONLY - does not touch any remote host. Run
# subs/sync_subscriptions.sh separately afterward to push to Caddy.
#
# Run this after deploy/deploy_nodes.sh and relay/deploy_mesh.sh so links
# reflect the current, live topology.
#
# Relay links are only generated for nodes with "is_relay_entry": true in
# inventory.json - curated on purpose, so link count grows with the number
# of entry nodes x N instead of N^2 as the mesh scales. Mark a node as a
# relay entry point by adding that field to it in inventory.json's nodes[].
#
# To hide nodes from a specific user, set "hidden_nodes": ["node_name", ...]
# on that user object in xray.users[]. The generator will skip both direct
# links and any relay links that would expose those nodes to that user.
#
# Usage: relay-mesh/subs/generate_subscriptions.sh [inventory.json]
#
# subs.domain/subs.sub_secret come from inventory.json. Export SUB_SECRET
# yourself to override the inventory value (e.g. after rotating it) without
# editing the file.
#
# Optional env:
#   SUB_SECRET   - overrides inventory.json's subs.sub_secret
#   SUB_DIR      - local output dir (default: ./subscriptions)
#   LINK_FP      - uTLS fingerprint in links (default: firefox)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"
# shellcheck source=lib/subs_render.sh
source "$SCRIPT_DIR/lib/subs_render.sh"

INVENTORY="${1:-$MESH_DIR/inventory.json}"

SUB_DIR="${SUB_DIR:-./subscriptions}"
LINK_FP="${LINK_FP:-firefox}"

check_deps() {
    local missing=() cmd
    for cmd in jq sha256sum base64; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing[*]}"
        exit 1
    fi
    command -v qrencode >/dev/null 2>&1 || warn "qrencode not found - sub.qr.png will be skipped"
}

check_deps
inv_validate "$INVENTORY" || exit 1

SUB_DOMAIN="$(inv_subs_domain "$INVENTORY")"
[ -n "$SUB_DOMAIN" ] || { error "subs.domain not set in $INVENTORY"; exit 1; }

: "${SUB_SECRET:=$(inv_subs_secret "$INVENTORY")}"
[ -n "$SUB_SECRET" ] || { error "subs.sub_secret not set in $INVENTORY (or export SUB_SECRET)"; exit 1; }

info "Building links from $INVENTORY..."
ALL_LINKS="$(build_all_links "$INVENTORY")" || exit 1
if [ -z "$ALL_LINKS" ]; then
    error "no links generated - check inventory has users and nodes"
    exit 1
fi

write_subscription_files "$SUB_DIR" "$SUB_SECRET" "$SUB_DOMAIN" "$ALL_LINKS"

info "Files written to $SUB_DIR. Run subs/sync_subscriptions.sh to push them to Caddy."
