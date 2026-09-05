#!/usr/bin/env bash
# Syncs generated subscription files to the Caddy host and reloads it.
# Mirrors the sync_and_start_caddy step in the old deploy.sh. Does NOT
# deploy Caddy itself - see relay-mesh/caddy/deploy_caddy.sh for that.
# Sourced by generate_subscriptions.sh - not meant to be run directly.

sync_subs_to_caddy() {
    local sub_dir="$1" sub_server="$2" caddy_deploy_dir="$3"
    local ssh_opt
    ssh_opt="$(mesh_ssh_opt)"

    info "Syncing subscription files to ${sub_server}:${caddy_deploy_dir}/subs/ ..."
    for user_dir in "$sub_dir"/*/; do
        [ -f "${user_dir}sub.token" ] || continue
        local token
        token=$(cat "${user_dir}sub.token")
        rsync -az --delete \
            --exclude='sub.token' --exclude='sub.links' --exclude='sub.qr.png' \
            -e "ssh $ssh_opt" \
            "${user_dir}" \
            "${SSH_USER}@${sub_server}:${caddy_deploy_dir}/subs/${token}/"
    done
    success "Subscription files synced to Caddy"

    reload_caddy "$sub_server" "$caddy_deploy_dir"
}

reload_caddy() {
    local sub_server="$1" caddy_deploy_dir="$2"
    local ssh_opt
    ssh_opt="$(mesh_ssh_opt)"

    if ssh $ssh_opt "${SSH_USER}@${sub_server}" \
        "docker compose -f ${caddy_deploy_dir}/compose.yml ps --quiet --status running caddy-subs 2>/dev/null | grep -q ." 2>/dev/null
    then
        # `caddy reload` needs the admin API, which caddy/Caddyfile disables
        # (`admin off`) - it always fails here, so go straight to a restart
        # instead of paying for a doomed attempt first.
        info "Restarting Caddy to pick up the synced files..."
        ssh $ssh_opt "${SSH_USER}@${sub_server}" \
            "docker compose -f ${caddy_deploy_dir}/compose.yml restart caddy-subs"
        success "Caddy restarted"
    else
        warn "Caddy not running on ${sub_server} - this script only syncs subscription content. Run relay-mesh/caddy/deploy_caddy.sh first to stand it up."
    fi
}
