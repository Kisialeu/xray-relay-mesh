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
        haproxy_check_stats_listener "$host" "$(inv_stats_public_port "$inventory")"
    fi
}
