#!/usr/bin/env bash

relay_validate_stage() {
    local host="$1" deploy_dir="$2" run_id="$3"
    remote_validate_stage "$host" "$deploy_dir" "$run_id" || return 1
    remote_bash "$host" "$deploy_dir/.staging/$run_id/config/haproxy.cfg" <<'REMOTE'
docker run --rm -v "$1:/usr/local/etc/haproxy/haproxy.cfg:ro" haproxy:alpine haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
REMOTE
}

relay_verify() {
    local host="$1" inventory="$2"
    compose_wait_healthy "$host" "${MESH_TIMEOUT:-120}" xray-relay || return 1
    if [ "$(inv_stats_expose_haproxy "$inventory")" = true ]; then
        relay_check_stats_listener "$host" "$(inv_stats_public_port "$inventory")"
    fi
}

relay_apply_stats_firewall() {
    local host="$1" port="$2" sources="$3" source
    if [ -z "$sources" ]; then
        warn "$host: stats.allowed_sources is empty; firewall is unchanged for port $port"
        return 0
    fi
    for source in $sources; do
        remote_bash "$host" "$source" "$port" <<'REMOTE'
set -euo pipefail
if ! sudo iptables -C INPUT -s "$1" -p tcp --dport "$2" -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT 1 -s "$1" -p tcp --dport "$2" -j ACCEPT
fi
REMOTE
    done
    remote_bash "$host" <<'REMOTE' || warn "$host: firewall rules are active but could not be persisted"
if command -v netfilter-persistent >/dev/null 2>&1; then
    sudo netfilter-persistent save >/dev/null
elif [ -d /etc/iptables ]; then
    sudo sh -c 'iptables-save > /etc/iptables/rules.v4'
fi
REMOTE
}

relay_check_stats_listener() {
    local host="$1" port="$2"
    remote_bash "$host" "$port" <<'REMOTE'
ss -lnt | awk '{print $4}' | grep -Eq "(^|:)$1$"
REMOTE
}
