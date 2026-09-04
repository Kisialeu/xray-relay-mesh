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
#   relay-mesh/mesh.sh deploy-caddy               deploy/update Caddy on subs.caddy_host
#   relay-mesh/mesh.sh subs-generate             generate subscriptions (local only)
#   relay-mesh/mesh.sh subs-sync                 sync generated subscriptions to Caddy
#   relay-mesh/mesh.sh rollback <name>           roll back relay config on one node
#   relay-mesh/mesh.sh prune-node <name>         remove remote Xray/relay deployment, keep inventory entry
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

INVENTORY="${INVENTORY:-$SCRIPT_DIR/inventory.json}"

pause() { read -r -p "Press Enter to continue..." _ || true; }

# Prints the node list to stderr (visible, not captured) and reads a name
# on stdin; only the entered name goes to stdout, for `node="$(prompt_node)"`.
prompt_node() {
    {
        echo ""
        echo "Nodes in $INVENTORY:"
        inv_node_names "$INVENTORY" | sed 's/^/  - /'
        echo ""
    } >&2
    read -r -p "Node name: " NODE_NAME
    echo "$NODE_NAME"
}

run_deploy_node_one()  { local node; node="$(prompt_node)"; "$SCRIPT_DIR/deploy/deploy_nodes.sh" "$node" "$INVENTORY"; }
run_deploy_node_all()  { "$SCRIPT_DIR/deploy/deploy_nodes.sh" all "$INVENTORY"; }
run_deploy_relay_one() { local node; node="$(prompt_node)"; "$SCRIPT_DIR/relay/deploy_mesh.sh" "$node" "$INVENTORY"; }
run_deploy_relay_all() { "$SCRIPT_DIR/relay/deploy_mesh.sh" all "$INVENTORY"; }
run_deploy_caddy()     { "$SCRIPT_DIR/caddy/deploy_caddy.sh" "$INVENTORY"; }
run_subs_generate()    { "$SCRIPT_DIR/subs/generate_subscriptions.sh" "$INVENTORY"; }
run_subs_sync()        { "$SCRIPT_DIR/subs/sync_subscriptions.sh" "$INVENTORY"; }
run_rollback()         { local node; node="$(prompt_node)"; "$SCRIPT_DIR/relay/rollback_mesh.sh" "$node" "$INVENTORY"; }
run_prune_node()       { local node; node="$(prompt_node)"; "$SCRIPT_DIR/prune-node/prune_node.sh" "$node" "$INVENTORY"; }
run_remove_node()      { local node; node="$(prompt_node)"; "$SCRIPT_DIR/remove-node/remove_node.sh" "$node" "$INVENTORY"; }
run_cert_setup()       { "$SCRIPT_DIR/certs/setup_cdn_cert.sh" "$INVENTORY"; }
run_cert_destroy()     { "$SCRIPT_DIR/certs/destroy_cdn_cert.sh" "$INVENTORY"; }

show_menu() {
    echo ""
    echo "================================================"
    echo " Relay Mesh - Stack Control  ($INVENTORY)"
    echo "================================================"
    echo "  1) Deploy Xray            - one node"
    echo "  2) Deploy Xray            - ALL nodes"
    echo "  3) Deploy relay (HAProxy) - one node"
    echo "  4) Deploy relay (HAProxy) - ALL nodes"
    echo "  6) Generate subscriptions (local only)"
    echo "  7) Sync subscriptions to Caddy"
    echo "  8) Deploy/update Caddy (subscription server)"
    echo "  9) Rollback relay config  - one node"
    echo "  110) Prune remote node     - keep inventory entry"
    echo "  109) Remove a node (decommission)"
    echo " 1103) Set up CDN certificate (CloudFront)"
    echo " 1749) Destroy CDN certificate (CloudFront)"

    echo "  0) Exit"
    echo "================================================"
}

interactive_menu() {
    while true; do
        show_menu
        read -r -p "Choose an option: " choice
        case "$choice" in
            1) run_deploy_node_one ;  pause ;;
            2) run_deploy_node_all ;  pause ;;
            3) run_deploy_relay_one ; pause ;;
            4) run_deploy_relay_all ; pause ;;
            6) run_subs_generate ;    pause ;;
            7) run_subs_sync ;        pause ;;
            8) run_deploy_caddy ;     pause ;;
            9) run_rollback ;         pause ;;
            110) run_prune_node ;      pause ;;
            109) run_remove_node ;      pause ;;
            1109) run_cert_setup ;      pause ;;
            1749) run_cert_destroy ;    pause ;;

            0) exit 0 ;;
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
    *)
        echo "Unknown command: $CMD" >&2
        echo "Run with no arguments for the interactive menu, or see this script's header comment for subcommands." >&2
        exit 1
        ;;
esac
