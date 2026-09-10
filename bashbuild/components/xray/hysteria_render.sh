#!/usr/bin/env bash
# Renders the Hysteria2 stack files (.env additions, hysteria/config.yaml)
# from inventory.json. Hysteria2 is a separate UDP/QUIC server, not an Xray
# protocol - see inv_hysteria_* / inv_node_tls_domain in ../../lib/inventory.sh
# and the "Hysteria2 (optional)" section of the top-level README.
# Sourced by the Xray component controller - not meant to be run directly.

# Always emitted (even when this node has no "hysteria" protocol) so
# HYSTERIA_IMAGE is available for the "hysteria" service's image default in
# docker-compose.xray.yml. Empty COMPOSE_PROFILES means docker compose skips
# that service entirely on this node - it's gated by `profiles: ["hysteria"]`,
# decided per node via inv_node_has_hysteria(), not a mesh-wide switch.
# HYSTERIA_STATS_SECRET/HYSTERIA_STATS_PORT let stats.py (running inside the
# xray container, same docker network) call hysteria's private trafficStats
# API - see the "trafficStats" block in render_hysteria_config below.
render_hysteria_env() {
    local file="$1" node="$2"
    local enabled img profiles="" secret="" port=""

    enabled=$(inv_node_has_hysteria "$file" "$node")
    img=$(inv_image_hysteria "$file")
    if [ "$enabled" = "true" ]; then
        profiles="hysteria"
        secret=$(inv_shared_hysteria_stats_secret "$file")
        port=$(inv_hysteria_stats_port "$file")
    fi

    cat << EOF
COMPOSE_PROFILES=${profiles}
HYSTERIA_IMAGE=${img}
HYSTERIA_STATS_SECRET=${secret}
HYSTERIA_STATS_PORT=${port}
EOF
}

# Port 443/tcp on this same host is already Xray's Reality listener, so ACME
# can't use the TLS-ALPN-01 challenge (needs to answer on 443/tcp itself) -
# "type: http" forces HTTP-01 on port 80/tcp instead, which is the only port
# docker-compose.xray.yml opens for the hysteria container besides its own
# UDP port. Cert cache is under /acme (bind-mounted from the host's
# hysteria/acme/ - see README, never touched by redeploys). The outbound
# "mode: 4" mirrors Xray's own outbounds (domainStrategy: UseIPv4 in
# render_xray_config_json) and the compose file's disabled IPv6 sysctls -
# these hosts have no real IPv6 route, so Hysteria2's default dual-stack
# "auto" outbound mode fails hard ("network is unreachable") instead of
# falling back to IPv4 whenever a client's destination resolves to IPv6.
render_hysteria_config() {
    local file="$1" node="$2"
    local port tls_domain email masquerade up down dns users_json userpass_lines obfs_password obfs_block=""
    local stats_secret stats_port

    port=$(inv_node_field "$file" "$node" direct_port)
    tls_domain=$(inv_node_tls_domain "$file" "$node")
    email=$(inv_hysteria_acme_email "$file")
    masquerade=$(inv_hysteria_masquerade_url "$file")
    up=$(inv_hysteria_up_mbps "$file")
    down=$(inv_hysteria_down_mbps "$file")
    dns=$(inv_xray_dns1 "$file")
    users_json=$(inv_xray_users_json "$file")
    obfs_password=$(inv_hysteria_obfs_password "$file")
    stats_secret=$(inv_shared_hysteria_stats_secret "$file")
    stats_port=$(inv_hysteria_stats_port "$file")

    if [ -z "$masquerade" ]; then
        masquerade="https://$(inv_xray_sni "$file")"
    fi

    if [ -n "$obfs_password" ]; then
        obfs_block="obfs:
  type: salamander
  salamander:
    password: $(jq -Rn --arg s "$obfs_password" '$s')

"
    fi

    # Same auth model as VLESS: one identity (email) per user, password reuses
    # their existing UUID - see build_hysteria2_link() in subs/lib/subs_render.sh,
    # which emits "email:uuid" as the link's userinfo to match this 1:1.
    userpass_lines=$(jq -r '.[] | "    \(.email | tostring | @json): \(.uuid | @json)"' <<< "$users_json")

    cat << EOF
listen: ":${port}"

${obfs_block}acme:
  domains:
    - $(jq -Rn --arg s "$tls_domain" '$s')
  email: $(jq -Rn --arg s "$email" '$s')
  type: http
  dir: /acme

auth:
  type: userpass
  userpass:
${userpass_lines}

resolver:
  type: udp
  udp:
    addr: "${dns}:53"
    timeout: 4s

masquerade:
  type: proxy
  proxy:
    url: $(jq -Rn --arg s "$masquerade" '$s')
    rewriteHost: true

bandwidth:
  up: ${up} mbps
  down: ${down} mbps

outbounds:
  - name: direct
    type: direct
    direct:
      mode: "4"

trafficStats:
  listen: ":${stats_port}"
  secret: $(jq -Rn --arg s "$stats_secret" '$s')
EOF
}
