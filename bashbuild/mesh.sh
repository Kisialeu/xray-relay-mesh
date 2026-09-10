#!/usr/bin/env bash
# Operator CLI for the Bash deployment framework.

set -uo pipefail

BASHBUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$BASHBUILD_DIR/lib/common.sh"
# shellcheck source=lib/inventory.sh
source "$BASHBUILD_DIR/lib/inventory.sh"
# shellcheck source=lib/stage.sh
source "$BASHBUILD_DIR/lib/stage.sh"
# shellcheck source=lib/args.sh
source "$BASHBUILD_DIR/lib/args.sh"
# shellcheck source=lib/commands.sh
source "$BASHBUILD_DIR/lib/commands.sh"

usage() {
    cat <<'USAGE'
Usage:
  ./mesh.sh                         interactive terminal UI
  ./mesh.sh check
  ./mesh.sh render <xray|relay> --node NAME --output DIR
  ./mesh.sh plan <component|all> [--node NAME]
  ./mesh.sh deploy <component|all> [--node NAME]
  ./mesh.sh status [--node NAME]
  ./mesh.sh rollback <component> --node NAME
  ./mesh.sh bootstrap --node NAME
  ./mesh.sh node <prune|remove|reset> --node NAME
  ./mesh.sh cdn <plan|apply|destroy>
  ./mesh.sh network
  ./mesh.sh stats tunnel
  ./mesh.sh adguard ui --node NAME
  ./mesh.sh subscription <access|verify>

Global options:
  --inventory PATH  --dry-run  --yes  --non-interactive
  --timeout SECONDS --verbose
USAGE
}

if [ $# -eq 0 ]; then
    INVENTORY="${INVENTORY:-$MESH_DIR/configs/inventory.json}"
    MESH_TIMEOUT="${MESH_TIMEOUT:-120}"
    export INVENTORY MESH_TIMEOUT
    # shellcheck source=lib/ui.sh
    source "$BASHBUILD_DIR/lib/ui.sh"
    mesh_ui_run
    exit $?
fi

mesh_parse_args "$@" || exit 1

case "$MESH_CLI_COMMAND" in
    check)
        "$MESH_DIR/bashbuild/scripts/check.sh"
        ;;
    render)
        [ "${#MESH_CLI_POSITIONAL[@]}" -eq 1 ] || { error "usage: mesh.sh render <component> --node NAME --output DIR"; exit 1; }
        mesh_command_render "$INVENTORY" "${MESH_CLI_POSITIONAL[0]}" "$MESH_CLI_NODE" "$MESH_CLI_OUTPUT"
        ;;
    plan)
        [ "${#MESH_CLI_POSITIONAL[@]}" -eq 1 ] || { error "usage: mesh.sh plan <component|all> [--node NAME]"; exit 1; }
        mesh_command_plan "$INVENTORY" "${MESH_CLI_POSITIONAL[0]}" "$MESH_CLI_NODE"
        ;;
    deploy)
        [ "${#MESH_CLI_POSITIONAL[@]}" -eq 1 ] || { error "usage: mesh.sh deploy <component|all> [--node NAME]"; exit 1; }
        if [ "$MESH_CLI_DRY_RUN" -eq 1 ]; then
            mesh_command_plan "$INVENTORY" "${MESH_CLI_POSITIONAL[0]}" "$MESH_CLI_NODE"
        else
            mesh_guard_non_interactive_change
            mesh_command_deploy "$INVENTORY" "${MESH_CLI_POSITIONAL[0]}" "$MESH_CLI_NODE"
        fi
        ;;
    status)
        [ "${#MESH_CLI_POSITIONAL[@]}" -eq 0 ] || { error "usage: mesh.sh status [--node NAME]"; exit 1; }
        mesh_command_status "$INVENTORY" "$MESH_CLI_NODE"
        ;;
    rollback)
        [ "${#MESH_CLI_POSITIONAL[@]}" -eq 1 ] || { error "usage: mesh.sh rollback <component> --node NAME"; exit 1; }
        mesh_require_node
        mesh_guard_non_interactive_change
        case "${MESH_CLI_POSITIONAL[0]}" in
            relay) source "$BASHBUILD_DIR/components/relay/deploy.sh"; relay_rollback_one "$INVENTORY" "$MESH_CLI_NODE" ;;
            xray|nodes) source "$BASHBUILD_DIR/components/xray/deploy.sh"; xray_rollback_one "$INVENTORY" "$MESH_CLI_NODE" ;;
            *) error "rollback is not available for component: ${MESH_CLI_POSITIONAL[0]}"; exit 1 ;;
        esac
        ;;
    bootstrap)
        mesh_require_node
        mesh_guard_non_interactive_change
        "$MESH_DIR/infrastructure/host/bootstrap.sh" "$MESH_CLI_NODE" "$INVENTORY"
        ;;
    node)
        [ "${#MESH_CLI_POSITIONAL[@]}" -eq 1 ] || { error "usage: mesh.sh node <prune|remove|reset> --node NAME"; exit 1; }
        mesh_require_node
        mesh_guard_non_interactive_change
        case "${MESH_CLI_POSITIONAL[0]}" in
            prune)
                node_args=("$MESH_CLI_NODE" "$INVENTORY")
                [ "$MESH_CLI_DRY_RUN" -eq 0 ] || node_args+=(--dry-run)
                "$MESH_DIR/infrastructure/host/prune.sh" "${node_args[@]}"
                ;;
            remove) "$MESH_DIR/infrastructure/host/remove.sh" "$MESH_CLI_NODE" "$INVENTORY" ;;
            reset) "$MESH_DIR/infrastructure/host/reset.sh" "$MESH_CLI_NODE" "$INVENTORY" ;;
            *) error "unknown node operation: ${MESH_CLI_POSITIONAL[0]}"; exit 1 ;;
        esac
        ;;
    cdn)
        [ "${#MESH_CLI_POSITIONAL[@]}" -eq 1 ] || { error "usage: mesh.sh cdn <plan|apply|destroy>"; exit 1; }
        case "${MESH_CLI_POSITIONAL[0]}" in
            plan) mesh_command_cdn_plan "$INVENTORY" ;;
            apply) mesh_guard_non_interactive_change; "$MESH_DIR/infrastructure/cdn/setup_cdn_cert.sh" "$INVENTORY" ;;
            destroy) mesh_guard_non_interactive_change; "$MESH_DIR/infrastructure/cdn/destroy_cdn_cert.sh" "$INVENTORY" ;;
            *) error "unknown CDN operation: ${MESH_CLI_POSITIONAL[0]}"; exit 1 ;;
        esac
        ;;
    stats)
        [ "${#MESH_CLI_POSITIONAL[@]}" -eq 1 ] && [ "${MESH_CLI_POSITIONAL[0]}" = tunnel ] \
            || { error "usage: mesh.sh stats tunnel"; exit 1; }
        "$MESH_DIR/bashbuild/components/stats/tunnel.sh" "$INVENTORY"
        ;;
    adguard)
        [ "${#MESH_CLI_POSITIONAL[@]}" -eq 1 ] && [ "${MESH_CLI_POSITIONAL[0]}" = ui ] \
            || { error "usage: mesh.sh adguard ui --node NAME"; exit 1; }
        mesh_require_node
        "$MESH_DIR/infrastructure/host/adguard_ui.sh" "$MESH_CLI_NODE" "$INVENTORY"
        ;;
    subscription|subscriptions)
        [ "${#MESH_CLI_POSITIONAL[@]}" -eq 1 ] \
            || { error "usage: mesh.sh subscription <access|verify>"; exit 1; }
        case "${MESH_CLI_POSITIONAL[0]}" in
            access) mesh_command_subscription_access "$INVENTORY" ;;
            verify) mesh_command_subscription_verify "$INVENTORY" ;;
            *) error "usage: mesh.sh subscription <access|verify>"; exit 1 ;;
        esac
        ;;
    network)
        [ "${#MESH_CLI_POSITIONAL[@]}" -eq 0 ] || { error "usage: mesh.sh network"; exit 1; }
        mesh_command_network "$INVENTORY"
        ;;
    *) error "unknown command: $MESH_CLI_COMMAND"; usage >&2; exit 1 ;;
esac
