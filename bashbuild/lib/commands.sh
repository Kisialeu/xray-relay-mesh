#!/usr/bin/env bash
# Explicit normalized CLI handlers. No dynamic component discovery.

mesh_preflight_node() {
    local inventory="$1" node="$2" host
    inv_node_exists "$inventory" "$node" || { error "node not found: $node"; return 1; }
    host="$(inv_node_field "$inventory" "$node" host)"
    mesh_resolve_ssh "$inventory" "$node"
    mesh_check_docker "$host"
    mesh_check_docker_compose "$host"
}

mesh_command_preflight_all() {
    local inventory="$1" node failed=0
    mesh_check_local_deps
    inv_validate "$inventory" || return 1
    while IFS= read -r node; do
        [ -n "$node" ] || continue
        mesh_preflight_node "$inventory" "$node" || failed=1
    done < <(inv_node_names "$inventory")
    [ "$failed" -eq 0 ]
}

mesh_component_configured() {
    local inventory="$1" component="$2"
    case "$component" in
        web) jq -e '(.stats.web_domain // "") != ""' "$inventory" >/dev/null ;;
        caddy) jq -e '(.subs.caddy_host // "") != "" and (.subs.domain // "") != ""' "$inventory" >/dev/null ;;
        *) return 0 ;;
    esac
}

mesh_command_deploy_all() {
    local inventory="$1"
    info "1/8 Preflighting all node targets"
    mesh_command_preflight_all "$inventory" || { error "deployment stopped: preflight failed"; return 1; }
    info "2/8 Deploying Xray/Hysteria node services"
    "$MESH_DIR/bashbuild/components/xray/deploy.sh" all "$inventory" || return 1
    info "3/8 Deploying relay routing"
    "$MESH_DIR/bashbuild/components/relay/deploy.sh" all "$inventory" || return 1
    info "4/8 Deploying central stats backend"
    "$MESH_DIR/bashbuild/components/stats/deploy.sh" "$inventory" || return 1
    if mesh_component_configured "$inventory" web; then
        info "5/8 Deploying stats web"
        "$MESH_DIR/bashbuild/components/web/deploy.sh" "$inventory" || return 1
    else
        info "5/8 Skipping stats web: not configured"
    fi
    if mesh_component_configured "$inventory" caddy; then
        info "6/8 Deploying Caddy"
        "$MESH_DIR/bashbuild/components/caddy/deploy.sh" "$inventory" || return 1
    else
        info "6/8 Skipping Caddy: not configured"
    fi
    info "7/8 Generating subscriptions"
    "$MESH_DIR/bashbuild/components/subscriptions/generate_subscriptions.sh" "$inventory" || return 1
    info "8/8 Syncing subscriptions"
    "$MESH_DIR/bashbuild/components/subscriptions/sync_subscriptions.sh" "$inventory"
}

mesh_command_deploy() {
    local inventory="$1" component="$2" node="$3" target
    case "$component" in
        all) [ -z "$node" ] || { error "--node is not valid with deploy all"; return 1; }; mesh_command_deploy_all "$inventory" ;;
        xray|nodes) target="${node:-all}"; "$MESH_DIR/bashbuild/components/xray/deploy.sh" "$target" "$inventory" ;;
        relay) target="${node:-all}"; "$MESH_DIR/bashbuild/components/relay/deploy.sh" "$target" "$inventory" ;;
        stats) [ -z "$node" ] || { error "--node is not valid for stats"; return 1; }; "$MESH_DIR/bashbuild/components/stats/deploy.sh" "$inventory" ;;
        web) [ -z "$node" ] || { error "--node is not valid for web"; return 1; }; "$MESH_DIR/bashbuild/components/web/deploy.sh" "$inventory" ;;
        caddy) [ -z "$node" ] || { error "--node is not valid for caddy"; return 1; }; "$MESH_DIR/bashbuild/components/caddy/deploy.sh" "$inventory" ;;
        subscriptions|subs)
            [ -z "$node" ] || { error "--node is not valid for subscriptions"; return 1; }
            "$MESH_DIR/bashbuild/components/subscriptions/generate_subscriptions.sh" "$inventory" && "$MESH_DIR/bashbuild/components/subscriptions/sync_subscriptions.sh" "$inventory"
            ;;
        *) error "unknown deploy component: $component"; return 1 ;;
    esac
}

mesh_command_plan() {
    local inventory="$1" component="$2" node="$3" item target
    local -a items=()
    inv_validate "$inventory" || return 1
    case "$component" in all) items=(xray relay stats web caddy subscriptions) ;; *) items=("$component") ;; esac
    printf 'Inventory: %s\n' "$inventory"
    printf 'Mode: read-only plan\n'
    for item in "${items[@]}"; do
        case "$item" in
            xray|nodes|relay)
                if [ -n "$node" ]; then
                    inv_node_exists "$inventory" "$node" || { error "node not found: $node"; return 1; }
                    printf '%s\t%s\twould preflight, render, validate, and compare managed manifest\n' "$item" "$node"
                else
                    while IFS= read -r target; do printf '%s\t%s\twould preflight, render, validate, and compare managed manifest\n' "$item" "$target"; done < <(inv_node_names "$inventory")
                fi
                ;;
            stats|web|caddy|subscriptions|subs) printf '%s\t%s\n' "$item" "would render, validate, compare, apply, verify, and rollback on failure" ;;
            *) error "unknown plan component: $item"; return 1 ;;
        esac
    done
    printf 'No local or remote state changed.\n'
}

mesh_command_render() {
    local inventory="$1" component="$2" node="$3" output="$4"
    [ -n "$node" ] || { error "render requires --node"; return 1; }
    [ -n "$output" ] || { error "render requires --output DIR to avoid printing secrets"; return 1; }
    inv_validate "$inventory" || return 1
    inv_node_exists "$inventory" "$node" || { error "node not found: $node"; return 1; }
    mkdir -p "$output"
    chmod 0700 "$output"

    case "$component" in
        relay)
            # shellcheck source=../components/relay/render_config.sh
            source "$MESH_DIR/bashbuild/components/relay/render_config.sh"
            render_haproxy_cfg "$inventory" "$node" > "$output/haproxy.cfg"
            chmod 0600 "$output/haproxy.cfg"
            ;;
        xray|nodes)
            # shellcheck source=../components/xray/render.sh
            source "$MESH_DIR/bashbuild/components/xray/render.sh"
            # shellcheck source=../components/xray/hysteria_render.sh
            source "$MESH_DIR/bashbuild/components/xray/hysteria_render.sh"
            mkdir -p "$output/config" "$output/adguard/conf"
            render_xray_env "$inventory" "$node" > "$output/.env"
            render_hysteria_env "$inventory" "$node" >> "$output/.env"
            render_xray_config_json "$inventory" "$node" > "$output/config/config.json"
            render_adguard_yaml "$inventory" > "$output/adguard/conf/AdGuardHome.yaml"
            cp "$MESH_DIR/services/xray/entrypoint.sh" "$output/entrypoint.sh"
            cp "$MESH_DIR/services/xray/stats.py" "$output/stats.py"
            cp "$MESH_DIR/services/xray/compose.yml" "$output/docker-compose.yml"
            chmod 0600 "$output/.env" "$output/config/config.json"
            chmod 0644 "$output/adguard/conf/AdGuardHome.yaml" "$output/stats.py" "$output/docker-compose.yml"
            chmod 0755 "$output/entrypoint.sh"
            if [ "$(inv_node_has_protocol "$inventory" "$node" hysteria)" = true ]; then
                mkdir -p "$output/hysteria"
                render_hysteria_config "$inventory" "$node" > "$output/hysteria/config.yaml"
                chmod 0600 "$output/hysteria/config.yaml"
            fi
            ;;
        *) error "render is not yet available for component: $component"; return 1 ;;
    esac
    stage_write_manifest "$output"
    success "rendered $component for $node to $output"
}

mesh_command_status() {
    local inventory="$1" selected_node="$2" node host result failed=0
    inv_validate "$inventory" || return 1
    while IFS= read -r node; do
        [ -n "$node" ] || continue
        [ -z "$selected_node" ] || [ "$node" = "$selected_node" ] || continue
        host="$(inv_node_field "$inventory" "$node" host)"
        mesh_resolve_ssh "$inventory" "$node"
        result="$(remote_bash "$host" <<'REMOTE' 2>/dev/null || true
for container in xray hysteria xray-relay xray-stats xray-stats-web xray-web-app; do
    state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)
    [ -n "$state" ] && printf '%s=%s ' "$container" "$state"
done
REMOTE
        )"
        if [ -n "$result" ]; then printf '%s\t%s\t%s\n' "$node" "$host" "$result"; else printf '%s\t%s\tunreachable-or-not-deployed\n' "$node" "$host"; failed=1; fi
    done < <(inv_node_names "$inventory")
    [ -z "$selected_node" ] || inv_node_exists "$inventory" "$selected_node" || { error "node not found: $selected_node"; return 1; }
    return "$failed"
}

mesh_command_cdn_plan() {
    local inventory="$1"
    inv_validate "$inventory" || return 1
    jq -r '"Domain: \(.subs.domain)\nZone: \(.subs.zone_domain)\nOrigin: \(.subs.caddy_host):8080\nActions: ACM certificate, CloudFront distribution, Route53 alias, origin firewall policy\nNo state changed."' "$inventory"
}
