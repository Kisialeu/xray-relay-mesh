#!/usr/bin/env bash
# Renders haproxy.cfg for one mesh node from an inventory.json file.
# mode tcp passthrough only - no TLS termination, no SNI routing.
# Sourced by other relay-mesh/*.sh scripts - not meant to be run directly.

render_haproxy_header() {
    local dns1="$1" dns2="$2" hold_valid="$3"
    cat << EOF
# Rendered by relay-mesh/relay/render_config.sh from inventory.json - do not edit by hand.
global
    maxconn 1000
    log stdout format raw local0

resolvers dns_resolver
    nameserver dns1 ${dns1}:53
    nameserver dns2 ${dns2}:53
    resolve_retries 3
    timeout resolve 1s
    timeout retry   1s
    hold valid ${hold_valid}
    hold obsolete 0s

defaults
    mode tcp
    log global
    timeout connect 10s
    timeout client 600s
    timeout server 600s
    option tcplog
    retries 3
EOF
}

render_haproxy_peer_block() {
    local peer_name="$1" peer_host="$2" peer_port="$3" relay_port="$4"
    cat << EOF

frontend relay_in_${peer_name}
    bind *:${relay_port}
    default_backend relay_out_${peer_name}

backend relay_out_${peer_name}
    option tcp-check
    tcp-check connect
    server ${peer_name} ${peer_host}:${peer_port} check inter 10s fall 3 rise 2 resolvers dns_resolver resolve-prefer ipv4 init-addr none
EOF
}

render_haproxy_stats_block() {
    local self="$1" node_port="$2" public_port="$3" token="$4" rate_period="$5" rate_requests="$6" allowed_sources="$7"
    cat << EOF

frontend stats_in_${self}
    mode http
    bind *:${public_port}
    option httplog
    stick-table type ip size 100k expire ${rate_period} store http_req_rate(${rate_period})
    http-request track-sc0 src
    http-request deny deny_status 429 if { sc_http_req_rate(0) gt ${rate_requests} }
EOF
    if [ -n "$allowed_sources" ]; then
        echo "    http-request deny deny_status 403 unless { src ${allowed_sources} }"
    fi
    cat << EOF
    http-request deny deny_status 403 unless { req.hdr(X-Stats-Token) -m str ${token} }
    http-request deny deny_status 404 unless { path -i /health /stats /online }
    default_backend stats_out_${self}

backend stats_out_${self}
    mode http
    option httpchk GET /health
    server local_stats 127.0.0.1:${node_port} check inter 10s fall 3 rise 2
EOF
}

# Prints the full haproxy.cfg for node $2, sourced from inventory file $1.
# One frontend+backend pair per peer (N-1 for a mesh of N nodes) - the node's
# own direct Xray port is never bound here, Xray owns that port directly.
render_haproxy_cfg() {
    local file="$1" self="$2"

    inv_validate "$file" || return 1
    if ! inv_node_exists "$file" "$self"; then
        error "node '$self' not found in inventory: $file"
        return 1
    fi

    render_haproxy_header "$(inv_dns1 "$file")" "$(inv_dns2 "$file")" "$(inv_hold_valid "$file")"

    local name host port relay_port
    while read -r name host port relay_port; do
        render_haproxy_peer_block "$name" "$host" "$port" "$relay_port"
    done < <(inv_peers_of "$file" "$self")

    if [ "$(inv_stats_expose_haproxy "$file")" = "true" ]; then
        local token allowed_sources
        token=$(inv_stats_token "$file")
        allowed_sources=$(inv_stats_allowed_sources "$file")
        if [ -z "$token" ]; then
            error "stats.expose_via_haproxy=true requires stats.token"
            return 1
        fi
        render_haproxy_stats_block \
            "$self" \
            "$(inv_stats_node_port "$file")" \
            "$(inv_stats_public_port "$file")" \
            "$token" \
            "$(inv_stats_rate_limit_period "$file")" \
            "$(inv_stats_rate_limit_requests "$file")" \
            "$allowed_sources"

    fi
}
