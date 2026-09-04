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
}
