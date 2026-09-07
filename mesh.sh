#!/usr/bin/env bash
# Single entrypoint for the whole relay-mesh stack. Run with no arguments
# for an interactive menu, or pass a subcommand directly for scripting.
# Everything here just shells out to the existing scripts under deploy/,
# relay/, subs/, certs/ - no deploy logic lives in this file.
#
# Usage:
#   relay-mesh/mesh.sh                          interactive menu
#   relay-mesh/mesh.sh check                    run read-only local validation
#
#   -- everything --
#   relay-mesh/mesh.sh deploy-all                deploy-nodes -> deploy-stats -> subs-generate -> subs-sync
#
#   -- xray / hysteria2 --
#   relay-mesh/mesh.sh deploy-node <name>        deploy Xray to one node (and Hysteria2, if enabled)
#   relay-mesh/mesh.sh deploy-nodes              deploy Xray to ALL nodes (and Hysteria2, if enabled)
#   relay-mesh/mesh.sh bootstrap-node <name>     install host deployment prerequisites
#
#   -- relay mesh --
#   relay-mesh/mesh.sh deploy-relay <name>       deploy relay mesh to one node
#   relay-mesh/mesh.sh deploy-relay-all          deploy relay mesh to ALL nodes
#   relay-mesh/mesh.sh deploy-stack-all          deploy Xray then relay to ALL nodes
#   relay-mesh/mesh.sh rollback <name>           roll back relay config on one node
#
#   -- subscriptions --
#   relay-mesh/mesh.sh deploy-caddy               deploy/update Caddy on subs.caddy_host
#   relay-mesh/mesh.sh subs-generate             generate subscriptions (local only)
#   relay-mesh/mesh.sh subs-sync                 sync generated subscriptions to Caddy
#
#   -- statistics --
#   relay-mesh/mesh.sh stats                     open SSH tunnel to central stats UI/API
#   relay-mesh/mesh.sh deploy-stats               deploy central stats backend to stats.master_node
#   relay-mesh/mesh.sh deploy-web                 deploy stats web + Certbot/Nginx to stats.master_node
#
#   -- node and certificate management --
#   relay-mesh/mesh.sh prune-node <name>         remove remote Xray/relay deployment, keep inventory entry
#   relay-mesh/mesh.sh reset-node <name>         hard-reset a node for redeployment
#   relay-mesh/mesh.sh remove-node <name>        decommission a node
#   relay-mesh/mesh.sh cert-setup                set up CDN cert (from inventory.json's subs block)
#   relay-mesh/mesh.sh cert-destroy               tear down CDN cert
#
# Env:
#   INVENTORY   - inventory.json path (default: relay-mesh/inventory.json)
#   Everything else (SSH_KEY, SSH_USER, SUB_SECRET, ORIGIN_VERIFY_SECRET, ...)
#   is read by the underlying scripts exactly as documented in their own headers.

set -uo pipefail   # no -e: menu loop must survive a failed action, not die

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/inventory.sh
source "$SCRIPT_DIR/lib/inventory.sh"
# shellcheck source=lib/stage.sh
source "$SCRIPT_DIR/lib/stage.sh"
# shellcheck source=lib/args.sh
source "$SCRIPT_DIR/lib/args.sh"
# shellcheck source=lib/commands.sh
source "$SCRIPT_DIR/lib/commands.sh"

INVENTORY="${INVENTORY:-$SCRIPT_DIR/inventory.json}"

pause() { read -r -p "Press Enter to continue..." _ || true; }

# Prints the node list to stderr (visible, not captured) and reads a number
# or name on stdin; only the resolved name goes to stdout.
prompt_node() {
    local -a nodes=()
    local name choice node index=1

    {
        echo ""
        echo "Select a node:"
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            nodes[index]="$name"
            printf '  %d) %s\n' "$index" "$(inv_node_friendly_name "$INVENTORY" "$name")"
            index=$((index + 1))
        done < <(inv_node_names "$INVENTORY")
        echo "     You can also enter the node name directly."
        echo ""
    } >&2

    read -r -p "Node: " choice || return 1
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        node="${nodes[$choice]-}"
        [ -n "$node" ] || { error "Unknown node selection: $choice"; return 1; }
    else
        inv_node_exists "$INVENTORY" "$choice" \
            || { error "Unknown node: $choice"; return 1; }
        node="$choice"
    fi
    printf '%s\n' "$node"
}

confirm_action() {
    local answer
    read -r -p "$1 [y/N]: " answer || return 1
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) info "Cancelled"; return 1 ;;
    esac
}

# ---- everything ----

run_deploy_all() {
    mesh_command_deploy_all "$INVENTORY"
}

# ---- xray / hysteria2 ----

run_deploy_node_one() {
    local node
    node="$(prompt_node)" || return 1
    "$SCRIPT_DIR/deploy/deploy_nodes.sh" "$node" "$INVENTORY"
}
run_deploy_node_all() {
    confirm_action "Deploy Xray to every node?" || return 0
    "$SCRIPT_DIR/deploy/deploy_nodes.sh" all "$INVENTORY"
}

# ---- relay mesh ----

run_deploy_stack_all() {
    info "Deploying Xray to all nodes before deploying relay mesh"
    "$SCRIPT_DIR/deploy/deploy_nodes.sh" all "$INVENTORY" \
        || { error "Combined deployment stopped: Xray deployment failed"; return 1; }
    "$SCRIPT_DIR/relay/deploy_mesh.sh" all "$INVENTORY" \
        || { error "Combined deployment failed: relay deployment failed"; return 1; }
}
run_deploy_relay_one() {
    local node
    node="$(prompt_node)" || return 1
    "$SCRIPT_DIR/relay/deploy_mesh.sh" "$node" "$INVENTORY"
}
run_deploy_relay_all() {
    confirm_action "Deploy relay routing to every node?" || return 0
    "$SCRIPT_DIR/relay/deploy_mesh.sh" all "$INVENTORY"
}
run_rollback() {
    local node
    node="$(prompt_node)" || return 1
    "$SCRIPT_DIR/relay/rollback_mesh.sh" "$node" "$INVENTORY"
}

# ---- subscriptions ----

run_deploy_caddy()     { "$SCRIPT_DIR/caddy/deploy_caddy.sh" "$INVENTORY"; }
run_subs_generate()    { "$SCRIPT_DIR/subs/generate_subscriptions.sh" "$INVENTORY"; }
run_subs_sync()        { "$SCRIPT_DIR/subs/sync_subscriptions.sh" "$INVENTORY"; }

# ---- statistics ----

run_stats()            { "$SCRIPT_DIR/stats/tunnel_stats.sh" "$INVENTORY"; }
run_deploy_stats()     { "$SCRIPT_DIR/stats/deploy_stats.sh" "$INVENTORY"; }
run_deploy_web()       { "$SCRIPT_DIR/web/deploy_web.sh" "$INVENTORY"; }

# ---- node and certificate management ----

run_prune_node() {
    local node
    node="$(prompt_node)" || return 1
    confirm_action "Remove deployed Xray and relay files from '$node' but keep its inventory entry?" || return 0
    "$SCRIPT_DIR/prune-node/prune_node.sh" "$node" "$INVENTORY"
}
run_reset_node() {
    local node
    node="$(prompt_node)" || return 1
    "$SCRIPT_DIR/reset-node/reset_node.sh" "$node" "$INVENTORY"
}
run_remove_node() {
    local node
    node="$(prompt_node)" || return 1
    confirm_action "Decommission '$node' and remove it from inventory?" || return 0
    "$SCRIPT_DIR/remove-node/remove_node.sh" "$node" "$INVENTORY"
}
run_cert_setup()       { "$SCRIPT_DIR/certs/setup_cdn_cert.sh" "$INVENTORY"; }
run_cert_destroy()     {
    confirm_action "Destroy the CloudFront/CDN certificate stack?" || return 0
    "$SCRIPT_DIR/certs/destroy_cdn_cert.sh" "$INVENTORY"
}

menu_title() {
    echo ""
    echo "================================================"
    echo " Relay Mesh - Stack Control ($INVENTORY)"
    echo "================================================"
}

show_main_menu() {
    menu_title
    echo "  1) Deploy everything (nodes + stats + subs)"
    echo "  2) Xray deployment"
    echo "  3) Relay routing"
    echo "  4) Subscriptions"
    echo "  5) Statistics"
    echo "  6) Node and certificate management"
    echo "  q) Quit"
    echo "================================================"
}

show_xray_menu() {
    menu_title
    echo " Xray deployment"
    echo "------------------------------------------------"
    echo "  1) Deploy Xray to one node"
    echo "  2) Deploy Xray to every node"
    echo "  3) Deploy Xray and relay to every node"
    echo "  b) Back"
    echo "================================================"
}

show_relay_menu() {
    menu_title
    echo " Relay routing"
    echo "------------------------------------------------"
    echo "  1) Deploy relay routing to one node"
    echo "  2) Deploy relay routing to every node"
    echo "  3) Roll back relay config on one node"
    echo "  b) Back"
    echo "================================================"
}

show_subscriptions_menu() {
    menu_title
    echo " Subscriptions"
    echo "------------------------------------------------"
    echo "  1) Generate subscription files locally"
    echo "  2) Sync generated subscriptions to Caddy"
    echo "  3) Deploy or update Caddy"
    echo "  b) Back"
    echo "================================================"
}

show_statistics_menu() {
    menu_title
    echo " Statistics"
    echo "------------------------------------------------"
    echo "  1) Open central statistics tunnel"
    echo "  2) Deploy central statistics backend"
    echo "  3) Deploy statistics website, Nginx and TLS"
    echo "  b) Back"
    echo "================================================"
}

show_management_menu() {
    menu_title
    echo " Node and certificate management"
    echo "------------------------------------------------"
    echo "  1) Clean deployed software from one node"
    echo "  2) Hard-reset one node for redeployment"
    echo "  3) Decommission and remove one node"
    echo "  4) Set up CDN certificate"
    echo "  5) Destroy CDN certificate"
    echo "  b) Back"
    echo "================================================"
}

xray_menu() {
    while true; do
        show_xray_menu
        read -r -p "Choose an option: " choice || exit 0
        case "$choice" in
            1) run_deploy_node_one ;  pause ;;
            2) run_deploy_node_all ;  pause ;;
            3) confirm_action "Deploy Xray and relay routing to every node?" \
                   && run_deploy_stack_all
               pause ;;
            b|B) return ;;
            q|Q|0) exit 0 ;;
            *) echo "Invalid option: $choice" ;;
        esac
    done
}

relay_menu() {
    while true; do
        show_relay_menu
        read -r -p "Choose an option: " choice || exit 0
        case "$choice" in
            1) run_deploy_relay_one ; pause ;;
            2) run_deploy_relay_all ; pause ;;
            3) run_rollback ;         pause ;;
            b|B) return ;;
            q|Q|0) exit 0 ;;
            *) echo "Invalid option: $choice" ;;
        esac
    done
}

subscriptions_menu() {
    while true; do
        show_subscriptions_menu
        read -r -p "Choose an option: " choice || exit 0
        case "$choice" in
            1) run_subs_generate ;    pause ;;
            2) run_subs_sync ;        pause ;;
            3) run_deploy_caddy ;     pause ;;
            b|B) return ;;
            q|Q|0) exit 0 ;;
            *) echo "Invalid option: $choice" ;;
        esac
    done
}

statistics_menu() {
    while true; do
        show_statistics_menu
        read -r -p "Choose an option: " choice || exit 0
        case "$choice" in
            1) run_stats ;;
            2) run_deploy_stats ;     pause ;;
            3) run_deploy_web ;       pause ;;
            b|B) return ;;
            q|Q|0) exit 0 ;;
            *) echo "Invalid option: $choice" ;;
        esac
    done
}

management_menu() {
    while true; do
        show_management_menu
        read -r -p "Choose an option: " choice || exit 0
        case "$choice" in
            1) run_prune_node ;       pause ;;
            2) run_reset_node ;       pause ;;
            3) run_remove_node ;      pause ;;
            4) run_cert_setup ;       pause ;;
            5) run_cert_destroy ;     pause ;;
            b|B) return ;;
            q|Q|0) exit 0 ;;
            *) echo "Invalid option: $choice" ;;
        esac
    done
}

interactive_menu() {
    while true; do
        show_main_menu
        read -r -p "Choose a section: " choice || exit 0
        case "$choice" in
            1) confirm_action "Deploy Xray/Hysteria2 to every node, redeploy the stats backend, and sync subscriptions?" \
                   && run_deploy_all
               pause ;;
            2) xray_menu ;;
            3) relay_menu ;;
            4) subscriptions_menu ;;
            5) statistics_menu ;;
            6) management_menu ;;
            q|Q|0) exit 0 ;;
            *) echo "Invalid option: $choice" ;;
        esac
    done
}

# ============================================================
# CLI dispatch (non-interactive / scriptable) - takes over when args are given
# ============================================================
if [ $# -eq 0 ]; then
    interactive_menu
    exit 0
fi

# Normalized CLI. Legacy commands below remain compatibility aliases.
NORMALIZED_CLI=0
case "$1" in
    check|render|plan|deploy|status|rollback|bootstrap|node|cdn|--*)
        NORMALIZED_CLI=1 ;;
esac
# Preserve the legacy `rollback <node>` alias. The normalized form is
# `rollback relay --node <node>`.
if [ "$1" = rollback ] && [ $# -eq 2 ]; then
    NORMALIZED_CLI=0
fi

if [ "$NORMALIZED_CLI" -eq 1 ]; then
        mesh_parse_args "$@" || exit 1
        case "$MESH_CLI_COMMAND" in
            check) "$SCRIPT_DIR/scripts/check.sh" ;;
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
                    mesh_guard_non_interactive_change || exit 1
                    mesh_command_deploy "$INVENTORY" "${MESH_CLI_POSITIONAL[0]}" "$MESH_CLI_NODE"
                fi
                ;;
            status)
                [ "${#MESH_CLI_POSITIONAL[@]}" -eq 0 ] || { error "usage: mesh.sh status [--node NAME]"; exit 1; }
                mesh_command_status "$INVENTORY" "$MESH_CLI_NODE"
                ;;
            rollback)
                [ "${#MESH_CLI_POSITIONAL[@]}" -eq 1 ] || { error "usage: mesh.sh rollback <component> --node NAME"; exit 1; }
                mesh_require_node || exit 1
                mesh_guard_non_interactive_change || exit 1
                case "${MESH_CLI_POSITIONAL[0]}" in
                    relay) "$SCRIPT_DIR/relay/rollback_mesh.sh" "$MESH_CLI_NODE" "$INVENTORY" ;;
                    *) error "rollback is not yet available for component: ${MESH_CLI_POSITIONAL[0]}"; exit 1 ;;
                esac
                ;;
            bootstrap)
                mesh_require_node || exit 1
                mesh_guard_non_interactive_change || exit 1
                "$SCRIPT_DIR/bootstrap/bootstrap_node.sh" "$MESH_CLI_NODE" "$INVENTORY"
                ;;
            node)
                [ "${#MESH_CLI_POSITIONAL[@]}" -eq 1 ] || { error "usage: mesh.sh node <prune|remove> --node NAME"; exit 1; }
                mesh_require_node || exit 1
                mesh_guard_non_interactive_change || exit 1
                case "${MESH_CLI_POSITIONAL[0]}" in
                    prune)
                        MESH_NODE_ARGS=("$MESH_CLI_NODE" "$INVENTORY")
                        [ "$MESH_CLI_DRY_RUN" -eq 0 ] || MESH_NODE_ARGS+=(--dry-run)
                        "$SCRIPT_DIR/prune-node/prune_node.sh" "${MESH_NODE_ARGS[@]}"
                        ;;
                    remove) "$SCRIPT_DIR/remove-node/remove_node.sh" "$MESH_CLI_NODE" "$INVENTORY" ;;
                    *) error "unknown node operation: ${MESH_CLI_POSITIONAL[0]}"; exit 1 ;;
                esac
                ;;
            cdn)
                [ "${#MESH_CLI_POSITIONAL[@]}" -eq 1 ] || { error "usage: mesh.sh cdn <plan|apply|destroy>"; exit 1; }
                case "${MESH_CLI_POSITIONAL[0]}" in
                    plan) mesh_command_cdn_plan "$INVENTORY" ;;
                    apply) mesh_guard_non_interactive_change && "$SCRIPT_DIR/certs/setup_cdn_cert.sh" "$INVENTORY" ;;
                    destroy) mesh_guard_non_interactive_change && "$SCRIPT_DIR/certs/destroy_cdn_cert.sh" "$INVENTORY" ;;
                    *) error "unknown CDN operation: ${MESH_CLI_POSITIONAL[0]}"; exit 1 ;;
                esac
                ;;
            *) error "unknown command: $MESH_CLI_COMMAND"; exit 1 ;;
        esac
        exit $?
fi

CMD="$1"; shift
case "$CMD" in
    # -- local validation --
    check)            "$SCRIPT_DIR/scripts/check.sh" ;;

    # -- everything --
    deploy-all)       run_deploy_all ;;

    # -- xray / hysteria2 --
    deploy-node)      "$SCRIPT_DIR/deploy/deploy_nodes.sh" "${1:?node name required}" "$INVENTORY" ;;
    deploy-nodes)     "$SCRIPT_DIR/deploy/deploy_nodes.sh" all "$INVENTORY" ;;
    bootstrap-node)   "$SCRIPT_DIR/bootstrap/bootstrap_node.sh" "${1:?node name required}" "$INVENTORY" ;;

    # -- relay mesh --
    deploy-stack-all) run_deploy_stack_all ;;
    deploy-relay)     "$SCRIPT_DIR/relay/deploy_mesh.sh" "${1:?node name required}" "$INVENTORY" ;;
    deploy-relay-all) "$SCRIPT_DIR/relay/deploy_mesh.sh" all "$INVENTORY" ;;
    rollback)         "$SCRIPT_DIR/relay/rollback_mesh.sh" "${1:?node name required}" "$INVENTORY" ;;

    # -- subscriptions --
    deploy-caddy)     "$SCRIPT_DIR/caddy/deploy_caddy.sh" "$INVENTORY" ;;
    subs-generate)    "$SCRIPT_DIR/subs/generate_subscriptions.sh" "$INVENTORY" ;;
    subs-sync)        "$SCRIPT_DIR/subs/sync_subscriptions.sh" "$INVENTORY" ;;

    # -- statistics --
    stats)            "$SCRIPT_DIR/stats/tunnel_stats.sh" "$INVENTORY" ;;
    deploy-stats)     "$SCRIPT_DIR/stats/deploy_stats.sh" "$INVENTORY" ;;
    deploy-web)       "$SCRIPT_DIR/web/deploy_web.sh" "$INVENTORY" ;;

    # -- node and certificate management --
    prune-node)       "$SCRIPT_DIR/prune-node/prune_node.sh" "${1:?node name required}" "$INVENTORY" "${2:-}" "${3:-}" ;;
    reset-node)       "$SCRIPT_DIR/reset-node/reset_node.sh" "${1:?node name required}" "$INVENTORY" ;;
    remove-node)      "$SCRIPT_DIR/remove-node/remove_node.sh" "${1:?node name required}" "$INVENTORY" ;;
    cert-setup)       "$SCRIPT_DIR/certs/setup_cdn_cert.sh" "$INVENTORY" ;;
    cert-destroy)     "$SCRIPT_DIR/certs/destroy_cdn_cert.sh" "$INVENTORY" ;;

    *)
        echo "Unknown command: $CMD" >&2
        echo "Run with no arguments for the interactive menu, or see this script's header comment for subcommands." >&2
        exit 1
        ;;
esac
