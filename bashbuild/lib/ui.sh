#!/usr/bin/env bash
# Interactive terminal UI. Every action delegates to the normalized CLI.

mesh_ui_pause() {
    printf '\n'
    read -r -p 'Press Enter to continue...' _ || true
}

mesh_ui_confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer || return 1
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) info "Cancelled"; return 1 ;;
    esac
}

mesh_ui_prompt_node() {
    local -a nodes=()
    local name choice node index=1
    inv_validate "$INVENTORY" || return 1
    printf '\nSelect a node:\n' >&2
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        nodes[index]="$name"
        printf '  %d) %s [%s]\n' "$index" "$(inv_node_friendly_name "$INVENTORY" "$name")" "$name" >&2
        index=$((index + 1))
    done < <(inv_node_names "$INVENTORY")
    printf '  Enter a number or node name.\n\n' >&2
    read -r -p 'Node: ' choice || return 1
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        node="${nodes[$choice]-}"
        [ -n "$node" ] || { error "unknown node selection: $choice"; return 1; }
    else
        inv_node_exists "$INVENTORY" "$choice" || { error "unknown node: $choice"; return 1; }
        node="$choice"
    fi
    printf '%s\n' "$node"
}

mesh_ui_exec() {
    if "$MESH_DIR/mesh.sh" --inventory "$INVENTORY" "$@"; then
        return 0
    fi
    error "command failed: mesh.sh $*"
    return 1
}

mesh_ui_title() {
    printf '\n============================================================\n'
    printf ' Xray Relay Mesh - %s\n' "$INVENTORY"
    printf '============================================================\n'
}

mesh_ui_xray_menu() {
    local choice node
    while true; do
        mesh_ui_title
        printf ' Xray and Hysteria\n'
        printf '  1) Deploy one node\n'
        printf '  2) Deploy every node\n'
        printf '  3) Roll back one node\n'
        printf '  4) Plan one node\n'
        printf '  b) Back\n'
        read -r -p 'Choose an option: ' choice || return 0
        case "$choice" in
            1) node=$(mesh_ui_prompt_node) && mesh_ui_exec deploy xray --node "$node"; mesh_ui_pause ;;
            2) mesh_ui_confirm "Deploy Xray and Hysteria to every node?" && mesh_ui_exec deploy xray; mesh_ui_pause ;;
            3) node=$(mesh_ui_prompt_node) && mesh_ui_confirm "Roll back Xray on '$node'?" && mesh_ui_exec rollback xray --node "$node"; mesh_ui_pause ;;
            4) node=$(mesh_ui_prompt_node) && mesh_ui_exec plan xray --node "$node"; mesh_ui_pause ;;
            b|B) return 0 ;;
            q|Q|0) exit 0 ;;
            *) error "invalid option: $choice" ;;
        esac
    done
}

mesh_ui_relay_menu() {
    local choice node
    while true; do
        mesh_ui_title
        printf ' Relay routing\n'
        printf '  1) Deploy one node\n'
        printf '  2) Deploy every node\n'
        printf '  3) Roll back one node\n'
        printf '  4) Plan one node\n'
        printf '  b) Back\n'
        read -r -p 'Choose an option: ' choice || return 0
        case "$choice" in
            1) node=$(mesh_ui_prompt_node) && mesh_ui_exec deploy relay --node "$node"; mesh_ui_pause ;;
            2) mesh_ui_confirm "Deploy relay routing to every node?" && mesh_ui_exec deploy relay; mesh_ui_pause ;;
            3) node=$(mesh_ui_prompt_node) && mesh_ui_confirm "Roll back relay on '$node'?" && mesh_ui_exec rollback relay --node "$node"; mesh_ui_pause ;;
            4) node=$(mesh_ui_prompt_node) && mesh_ui_exec plan relay --node "$node"; mesh_ui_pause ;;
            b|B) return 0 ;;
            q|Q|0) exit 0 ;;
            *) error "invalid option: $choice" ;;
        esac
    done
}

mesh_ui_delivery_menu() {
    local choice
    while true; do
        mesh_ui_title
        printf ' Subscriptions and Caddy\n'
        printf '  1) Generate and sync subscriptions\n'
        printf '  2) Deploy Caddy\n'
        printf '  3) Plan subscriptions and Caddy\n'
        printf '  b) Back\n'
        read -r -p 'Choose an option: ' choice || return 0
        case "$choice" in
            1) mesh_ui_exec deploy subscriptions; mesh_ui_pause ;;
            2) mesh_ui_exec deploy caddy; mesh_ui_pause ;;
            3) mesh_ui_exec plan subscriptions; mesh_ui_exec plan caddy; mesh_ui_pause ;;
            b|B) return 0 ;;
            q|Q|0) exit 0 ;;
            *) error "invalid option: $choice" ;;
        esac
    done
}

mesh_ui_stats_menu() {
    local choice
    while true; do
        mesh_ui_title
        printf ' Statistics\n'
        printf '  1) Open statistics tunnel\n'
        printf '  2) Deploy statistics backend\n'
        printf '  3) Deploy statistics web frontend\n'
        printf '  b) Back\n'
        read -r -p 'Choose an option: ' choice || return 0
        case "$choice" in
            1) mesh_ui_exec stats tunnel ;;
            2) mesh_ui_exec deploy stats; mesh_ui_pause ;;
            3) mesh_ui_exec deploy web; mesh_ui_pause ;;
            b|B) return 0 ;;
            q|Q|0) exit 0 ;;
            *) error "invalid option: $choice" ;;
        esac
    done
}

mesh_ui_management_menu() {
    local choice node
    while true; do
        mesh_ui_title
        printf ' Host and infrastructure management\n'
        printf '  1) Bootstrap one node\n'
        printf '  2) Prune one node deployment\n'
        printf '  3) Reset one node\n'
        printf '  4) Remove one inventory node\n'
        printf '  5) Plan CDN\n'
        printf '  6) Apply CDN\n'
        printf '  7) Destroy CDN\n'
        printf '  b) Back\n'
        read -r -p 'Choose an option: ' choice || return 0
        case "$choice" in
            1) node=$(mesh_ui_prompt_node) && mesh_ui_confirm "Bootstrap '$node'?" && mesh_ui_exec bootstrap --node "$node"; mesh_ui_pause ;;
            2) node=$(mesh_ui_prompt_node) && mesh_ui_exec node prune --node "$node"; mesh_ui_pause ;;
            3) node=$(mesh_ui_prompt_node) && mesh_ui_exec node reset --node "$node"; mesh_ui_pause ;;
            4) node=$(mesh_ui_prompt_node) && mesh_ui_confirm "Remove '$node' from inventory?" && mesh_ui_exec node remove --node "$node"; mesh_ui_pause ;;
            5) mesh_ui_exec cdn plan; mesh_ui_pause ;;
            6) mesh_ui_confirm "Apply billable CDN infrastructure changes?" && mesh_ui_exec cdn apply; mesh_ui_pause ;;
            7) mesh_ui_confirm "Destroy CDN infrastructure?" && mesh_ui_exec cdn destroy; mesh_ui_pause ;;
            b|B) return 0 ;;
            q|Q|0) exit 0 ;;
            *) error "invalid option: $choice" ;;
        esac
    done
}

mesh_ui_run() {
    local choice node
    while true; do
        mesh_ui_title
        printf '  1) Deploy everything\n'
        printf '  2) Xray and Hysteria\n'
        printf '  3) Relay routing\n'
        printf '  4) Subscriptions and Caddy\n'
        printf '  5) Statistics\n'
        printf '  6) Status\n'
        printf '  7) Local checks\n'
        printf '  8) Host and infrastructure management\n'
        printf '  q) Quit\n'
        read -r -p 'Choose a section: ' choice || return 0
        case "$choice" in
            1) mesh_ui_confirm "Deploy all configured services serially?" && mesh_ui_exec deploy all; mesh_ui_pause ;;
            2) mesh_ui_xray_menu ;;
            3) mesh_ui_relay_menu ;;
            4) mesh_ui_delivery_menu ;;
            5) mesh_ui_stats_menu ;;
            6)
                read -r -p 'Node name, or Enter for all: ' node || true
                if [ -n "$node" ]; then mesh_ui_exec status --node "$node"; else mesh_ui_exec status; fi
                mesh_ui_pause
                ;;
            7) mesh_ui_exec check; mesh_ui_pause ;;
            8) mesh_ui_management_menu ;;
            q|Q|0) return 0 ;;
            *) error "invalid option: $choice" ;;
        esac
    done
}
