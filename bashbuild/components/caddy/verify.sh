#!/usr/bin/env bash

caddy_prepare_content_dir() {
    local host="$1" content_dir="$2"
    remote_bash "$host" "$content_dir" <<'REMOTE'
sudo install -d -m 0755 "$1"
REMOTE
}

caddy_validate_stage() {
    local host="$1" deploy_dir="$2" run_id="$3"
    remote_validate_stage "$host" "$deploy_dir" "$run_id" || return 1
    remote_bash "$host" "$deploy_dir/.staging/$run_id" <<'REMOTE'
set -euo pipefail
cd "$1"
sudo docker compose -f compose.yml run --rm --no-deps --quiet-pull --entrypoint caddy caddy-subs \
    validate --config /etc/caddy/Caddyfile --adapter caddyfile
REMOTE
}

caddy_verify() {
    local host="$1"
    compose_wait_healthy "$host" "${MESH_TIMEOUT:-120}" caddy-subs || return 1
    remote_bash "$host" <<'REMOTE'
sudo docker exec caddy-subs wget -qO- http://127.0.0.1:8080/healthz >/dev/null
REMOTE
}
