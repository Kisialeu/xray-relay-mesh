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
            # shellcheck source=../components/xray/stage.sh
            source "$MESH_DIR/bashbuild/components/xray/stage.sh"
            xray_render_stage "$inventory" "$node" "$output"
            ;;
        *) error "render is not yet available for component: $component"; return 1 ;;
    esac
    [ -f "$output/.mesh-manifest" ] || stage_write_manifest "$output"
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

# Registrable-domain heuristic: strips the leftmost label unless the domain
# already has 2 labels. Good enough for this project's real domains
# (*.kisialeu.com, *.paravozik.click) - inventory has no explicit zone field
# for anything but subs.zone_domain, so every other zone is inferred.
mesh_network_zone_of() {
    local domain="$1"
    local -a labels
    IFS='.' read -r -a labels <<< "$domain"
    if [ "${#labels[@]}" -gt 2 ]; then
        printf '%s\n' "${domain#*.}"
    else
        printf '%s\n' "$domain"
    fi
}

# Dynamically derives, from the current inventory, which inbound ports each
# node needs open and which Route53 records must exist - so this never goes
# stale as nodes/protocols/flags change. Read-only: never touches a remote
# host or AWS.
mesh_command_network() {
    local inventory="$1"
    inv_validate "$inventory" || return 1

    local stats_exposed stats_public_port stats_master web_port stats_allowed
    stats_exposed=$(inv_stats_expose_haproxy "$inventory")
    stats_public_port=$(inv_stats_public_port "$inventory")
    stats_master=$(inv_stats_master_node "$inventory")
    web_port=$(inv_stats_web_port "$inventory")
    stats_allowed=$(inv_stats_allowed_sources "$inventory")

    local caddy_host caddy_prefix="" caddy_ip=""
    caddy_host=$(inv_subs_caddy_host "$inventory")
    if [ -n "$caddy_host" ]; then
        caddy_prefix=${caddy_host%%.*}
        caddy_ip=$(jq -r --arg n "$caddy_prefix" '.nodes[] | select(.name == $n) | .host // ""' "$inventory")
    fi

    printf 'Network requirements for %s\n' "$inventory"
    printf 'Read-only report generated from the current inventory - no state changed.\n'
    printf '\nInbound firewall / security-group rules, per node:\n'

    local name host direct_port is_relay_entry has_hysteria
    while IFS=$'\t' read -r name host direct_port is_relay_entry; do
        printf '\n%s (%s):\n' "$name" "$host"
        printf '  %-12s %s\n' "$direct_port/tcp" "Xray direct (VLESS+Reality)"
        has_hysteria=$(inv_node_has_hysteria "$inventory" "$name")
        if [ "$has_hysteria" = true ]; then
            printf '  %-12s %s\n' "$direct_port/udp" "Hysteria2 (QUIC)"
            printf '  %-12s %s\n' "80/tcp" "Hysteria2 ACME HTTP-01 challenge (needed continuously, for renewal)"
        fi
        if [ "$stats_exposed" = true ]; then
            printf '  %-12s %s\n' "$stats_public_port/tcp" "stats scrape endpoint via HAProxy (restrict to: ${stats_allowed:-none set - currently open to any source})"
        fi
        if [ "$name" = "$stats_master" ]; then
            printf '  %-12s %s\n' "$web_port/tcp" "stats web dashboard (HTTPS)"
        fi
        if [ -n "$caddy_prefix" ] && [ "$name" = "$caddy_prefix" ]; then
            printf '  %-12s %s\n' "8080/tcp" "Caddy subscriptions origin (restrict to CloudFront IP ranges)"
        fi
        if [ "$is_relay_entry" = true ]; then
            while IFS=$'\t' read -r peer_name relay_port; do
                printf '  %-12s %s\n' "$relay_port/tcp" "relay entry -> $peer_name"
            done < <(inv_peers_of "$inventory" "$name" | awk '{print $1"\t"$4}')
        fi
    done < <(jq -r '.nodes[] | "\(.name)\t\(.host)\t\(.direct_port)\t\(.is_relay_entry // false)"' "$inventory")

    if ! jq -e '[.nodes[] | select(.is_relay_entry == true)] | length > 0' "$inventory" >/dev/null 2>&1; then
        printf '\n(no node has "is_relay_entry": true yet - no public relay ports are required)\n'
    fi

    printf '\nDNS records to create in Route53:\n'

    local dns_lines=""
    while IFS=$'\t' read -r name host tls_domain; do
        [ -n "$tls_domain" ] || continue
        dns_lines+="$(mesh_network_zone_of "$tls_domain")|$tls_domain|A -> $host|tls_domain for node $name (Hysteria2 ACME needs this resolvable first)"$'\n'
    done < <(jq -r '.nodes[] | "\(.name)\t\(.host)\t\(.tls_domain // "")"' "$inventory")

    if [ -n "$caddy_host" ]; then
        if [ -n "$caddy_ip" ]; then
            dns_lines+="$(mesh_network_zone_of "$caddy_host")|$caddy_host|A -> $caddy_ip|Caddy subscriptions origin"$'\n'
        else
            dns_lines+="$(mesh_network_zone_of "$caddy_host")|$caddy_host|A -> ? (no node named '$caddy_prefix' - set manually)|Caddy subscriptions origin"$'\n'
        fi
    fi

    local web_domain master_ip
    web_domain=$(jq -r '.stats.web_domain // ""' "$inventory")
    if [ -n "$web_domain" ] && [ -n "$stats_master" ]; then
        master_ip=$(jq -r --arg n "$stats_master" '.nodes[] | select(.name == $n) | .host // ""' "$inventory")
        dns_lines+="$(mesh_network_zone_of "$web_domain")|$web_domain|A -> $master_ip|stats web dashboard ($stats_master)"$'\n'
    fi

    local subs_domain
    subs_domain=$(inv_subs_domain "$inventory")
    if [ -n "$subs_domain" ]; then
        dns_lines+="$(mesh_network_zone_of "$subs_domain")|$subs_domain|CNAME/ALIAS -> CloudFront distribution|subscriptions CDN domain, see \`mesh.sh cdn plan\`"$'\n'
    fi

    if [ -z "$dns_lines" ]; then
        printf '\n(no domains configured)\n'
    else
        local last_zone="" zone domain target note
        while IFS='|' read -r zone domain target note; do
            [ -n "$zone" ] || continue
            if [ "$zone" != "$last_zone" ]; then
                printf '\n  Zone: %s\n' "$zone"
                last_zone="$zone"
            fi
            printf '    %-28s %-40s %s\n' "$domain" "$target" "$note"
        done < <(printf '%s' "$dns_lines" | sort -t'|' -k1,1 -k2,2)
    fi

    printf '\nNo state changed - this is a read-only report.\n'
}
