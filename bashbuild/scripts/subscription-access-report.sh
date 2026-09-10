#!/usr/bin/env bash
# Validates an inventory and prints the subscription profiles visible per user.
# It intentionally does not render or print connection URLs, hosts, or UUIDs.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INVENTORY="${1:-$ROOT_DIR/configs/inventory.json}"

if [ "$#" -gt 1 ]; then
	printf 'Usage: %s [inventory.json]\n' "$0" >&2
	exit 2
fi

# shellcheck source=../lib/common.sh
source "$ROOT_DIR/bashbuild/lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$ROOT_DIR/bashbuild/lib/inventory.sh"
# shellcheck source=../components/subscriptions/render.sh
source "$ROOT_DIR/bashbuild/components/subscriptions/render.sh"

inv_validate "$INVENTORY"

direct_nodes=$(jq -r '.nodes[] | [.name, (.friendly_name // .name)] | @tsv' "$INVENTORY")
relay_pairs=$(build_relay_pairs "$INVENTORY")

while IFS= read -r email; do
	[ -n "$email" ] || continue
	printf '%s\n' "$email"
	profile_count=0

	while IFS=$'\t' read -r node_name display_name; do
		[ -n "$node_name" ] || continue
		if user_direct_visible "$INVENTORY" "$node_name" "$email" xray; then
			printf '  - %s (tcp)\n' "$display_name"
			profile_count=$((profile_count + 1))
		fi
		if [ "$(inv_node_has_hysteria "$INVENTORY" "$node_name")" = true ] &&
			user_direct_visible "$INVENTORY" "$node_name" "$email" hysteria; then
			printf '  - %s (udp)\n' "$display_name"
			profile_count=$((profile_count + 1))
		fi
	done <<<"$direct_nodes"

	while IFS=$'\t' read -r entry_name entry_display _entry_host destination_name destination_display _relay_port; do
		[ -n "$entry_name" ] || continue
		if user_relay_visible "$INVENTORY" "$entry_name" "$destination_name" "$email"; then
			printf '  - %s via %s (relay)\n' "$destination_display" "$entry_display"
			profile_count=$((profile_count + 1))
		fi
	done <<<"$relay_pairs"

	[ "$profile_count" -gt 0 ] || printf '  - (no profiles)\n'
done < <(jq -r '.xray.users[].email' "$INVENTORY")
