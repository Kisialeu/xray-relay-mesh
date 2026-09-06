#!/usr/bin/env bash
# Single entrypoint for the whole relay-mesh stack. Run with no arguments
# for an interactive menu, or pass a subcommand directly for scripting.
# Everything here just shells out to the existing scripts under deploy/,
# relay/, subs/, certs/ - no deploy logic lives in this file.
#
# Usage:
#   relay-mesh/mesh.sh                          interactive menu
#   relay-mesh/mesh.sh deploy-node <name>        deploy Xray to one node
#   relay-mesh/mesh.sh deploy-nodes              deploy Xray to ALL nodes
#   relay-mesh/mesh.sh deploy-relay <name>       deploy relay mesh to one node
#   relay-mesh/mesh.sh deploy-relay-all          deploy relay mesh to ALL nodes
#   relay-mesh/mesh.sh deploy-stack-all          deploy Xray then relay to ALL nodes
#   relay-mesh/mesh.sh deploy-caddy               deploy/update Caddy on subs.caddy_host
#   relay-mesh/mesh.sh subs-generate             generate subscriptions (local only)
#   relay-mesh/mesh.sh subs-sync                 sync generated subscriptions to Caddy
#   relay-mesh/mesh.sh rollback <name>           roll back relay config on one node
#   relay-mesh/mesh.sh prune-node <name>         remove remote Xray/relay deployment, keep inventory entry
#   relay-mesh/mesh.sh remove-node <name>        decommission a node
#   relay-mesh/mesh.sh cert-setup                set up CDN cert (from inventory.json's subs block)
#   relay-mesh/mesh.sh cert-destroy               tear down CDN cert
#   relay-mesh/mesh.sh stats                     open SSH tunnel to central stats UI/API
#   relay-mesh/mesh.sh deploy-stats              deploy central stats backend to stats.master_node
#   relay-mesh/mesh.sh deploy-web                deploy stats web + Certbot/Nginx to stats.master_node
#   relay-mesh/mesh.sh reset-node <name>    hard-reset a node for redeployment
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

run_deploy_node_one() {
    local node
    node="$(prompt_node)" || return 1
    "$SCRIPT_DIR/deploy/deploy_nodes.sh" "$node" "$INVENTORY"
}
run_deploy_node_all() {
    confirm_action "Deploy Xray to every node?" || return 0
    "$SCRIPT_DIR/deploy/deploy_nodes.sh" all "$INVENTORY"
}
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
run_deploy_caddy()     { "$SCRIPT_DIR/caddy/deploy_caddy.sh" "$INVENTORY"; }
run_subs_generate()    { "$SCRIPT_DIR/subs/generate_subscriptions.sh" "$INVENTORY"; }
run_subs_sync()        { "$SCRIPT_DIR/subs/sync_subscriptions.sh" "$INVENTORY"; }
run_rollback() {
    local node
    node="$(prompt_node)" || return 1
    "$SCRIPT_DIR/relay/rollback_mesh.sh" "$node" "$INVENTORY"
}
run_prune_node() {
    local node
    node="$(prompt_node)" || return 1
    confirm_action "Remove deployed Xray and relay files from '$node' but keep its inventory entry?" || return 0
    "$SCRIPT_DIR/prune-node/prune_node.sh" "$node" "$INVENTORY"
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
run_stats()            { "$SCRIPT_DIR/stats/tunnel_stats.sh" "$INVENTORY"; }
run_deploy_stats()     { "$SCRIPT_DIR/stats/deploy_stats.sh" "$INVENTORY"; }
run_deploy_web()       { "$SCRIPT_DIR/web/deploy_web.sh" "$INVENTORY"; }
run_reset_node() {
    local node
    node="$(prompt_node)" || return 1
    "$SCRIPT_DIR/reset-node/reset_node.sh" "$node" "$INVENTORY"
}

menu_title() {
    echo ""
    echo "================================================"
    echo " Relay Mesh - Stack Control ($INVENTORY)"
    echo "================================================"
}

show_main_menu() {
    menu_title
    echo "  1) Xray deployment"
    echo "  2) Relay routing"
    echo "  3) Subscriptions"
    echo "  4) Statistics"
    echo "  5) Node and certificate management"
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
            1) xray_menu ;;
            2) relay_menu ;;
            3) subscriptions_menu ;;
            4) statistics_menu ;;
            5) management_menu ;;
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

CMD="$1"; shift
case "$CMD" in
    deploy-node)      "$SCRIPT_DIR/deploy/deploy_nodes.sh" "${1:?node name required}" "$INVENTORY" ;;
    deploy-nodes)     "$SCRIPT_DIR/deploy/deploy_nodes.sh" all "$INVENTORY" ;;
    deploy-stack-all) run_deploy_stack_all ;;
    deploy-relay)     "$SCRIPT_DIR/relay/deploy_mesh.sh" "${1:?node name required}" "$INVENTORY" ;;
    deploy-relay-all) "$SCRIPT_DIR/relay/deploy_mesh.sh" all "$INVENTORY" ;;
    deploy-caddy)     "$SCRIPT_DIR/caddy/deploy_caddy.sh" "$INVENTORY" ;;
    subs-generate)    "$SCRIPT_DIR/subs/generate_subscriptions.sh" "$INVENTORY" ;;
    subs-sync)        "$SCRIPT_DIR/subs/sync_subscriptions.sh" "$INVENTORY" ;;
    rollback)         "$SCRIPT_DIR/relay/rollback_mesh.sh" "${1:?node name required}" "$INVENTORY" ;;
    prune-node)       "$SCRIPT_DIR/prune-node/prune_node.sh" "${1:?node name required}" "$INVENTORY" "${2:-}" "${3:-}" ;;
    remove-node)      "$SCRIPT_DIR/remove-node/remove_node.sh" "${1:?node name required}" "$INVENTORY" ;;
    cert-setup)       "$SCRIPT_DIR/certs/setup_cdn_cert.sh" "$INVENTORY" ;;
    cert-destroy)     "$SCRIPT_DIR/certs/destroy_cdn_cert.sh" "$INVENTORY" ;;
    stats)            "$SCRIPT_DIR/stats/tunnel_stats.sh" "$INVENTORY" ;;
    deploy-stats)     "$SCRIPT_DIR/stats/deploy_stats.sh" "$INVENTORY" ;;
    deploy-web)       "$SCRIPT_DIR/web/deploy_web.sh" "$INVENTORY" ;;
    reset-node)       "$SCRIPT_DIR/reset-node/reset_node.sh" "${1:?node name required}" "$INVENTORY" ;;
    *)
        echo "Unknown command: $CMD" >&2
        echo "Run with no arguments for the interactive menu, or see this script's header comment for subcommands." >&2
        exit 1
        ;;
esac
