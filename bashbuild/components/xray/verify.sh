#!/usr/bin/env bash

xray_remote_preflight() {
    local host="$1" deploy_dir="$2" hysteria_enabled="$3"
    remote_preflight "$host" "$deploy_dir" || return 1
    remote_bash "$host" "$hysteria_enabled" <<'REMOTE'
set -euo pipefail
command -v zstd >/dev/null
command -v cron >/dev/null || command -v crond >/dev/null
[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ]
if [ "$1" = true ]; then
    current=$(sysctl -n net.core.rmem_max 2>/dev/null)
    [ "${current:-0}" -ge 16777216 ]
fi
REMOTE
}

xray_prepare_persistent() {
    local host="$1" deploy_dir="$2" hysteria_enabled="$3"
    remote_bash "$host" "$deploy_dir" "$hysteria_enabled" <<'REMOTE'
set -euo pipefail
deploy=$1
sudo install -d -m 0755 "$deploy/logs" "$deploy/adguard/work"
if [ "$2" = true ]; then
    sudo install -d -m 0700 "$deploy/hysteria/acme"
fi
REMOTE
}

xray_validate_stage() {
    local host="$1" deploy_dir="$2" run_id="$3" hysteria_enabled="$4"
    remote_validate_stage "$host" "$deploy_dir" "$run_id" || return 1
    remote_bash "$host" "$deploy_dir/.staging/$run_id" "$hysteria_enabled" <<'REMOTE'
set -euo pipefail
stage=$1
xray_image=$(awk -F= '$1 == "XRAY_IMAGE" { print substr($0, index($0, "=") + 1) }' "$stage/.env")
[ -n "$xray_image" ]
sudo docker run --rm --network none \
    -v "$stage/config/config.json:/etc/xray/config.json:ro" \
    "$xray_image" run -test -config /etc/xray/config.json
if [ "$2" = true ]; then
    hysteria_image=$(awk -F= '$1 == "HYSTERIA_IMAGE" { print substr($0, index($0, "=") + 1) }' "$stage/.env")
    [ -n "$hysteria_image" ]
    sudo docker run --rm --network none \
        -v "$stage/hysteria/config.yaml:/etc/hysteria/config.yaml:ro" \
        "$hysteria_image" server -c /etc/hysteria/config.yaml --check
fi
REMOTE
}

xray_sync_system_hooks() {
    local host="$1" deploy_dir="$2"
    remote_bash "$host" "$deploy_dir" <<'REMOTE'
set -euo pipefail
deploy=$1
sync_link() {
    source_path=$1
    target_path=$2
    if [ -f "$source_path" ]; then
        sudo ln -sfn "$source_path" "$target_path"
    elif [ -L "$target_path" ] && [ "$(readlink "$target_path")" = "$source_path" ]; then
        sudo rm -f -- "$target_path"
    fi
}
sync_link "$deploy/system/xray-logrotate.conf" /etc/logrotate.d/xray
sync_link "$deploy/system/xray-restart.cron" /etc/cron.d/xray-restart
REMOTE
}

xray_remove_disabled_hysteria() {
    local host="$1" deploy_dir="$2" hysteria_enabled="$3"
    [ "$hysteria_enabled" = true ] && return 0
    remote_bash "$host" "$deploy_dir" <<'REMOTE'
set -euo pipefail
cd "$1"
sudo docker compose --profile hysteria rm -sf hysteria
REMOTE
}

xray_remote_hysteria_enabled() {
    local host="$1" deploy_dir="$2"
    remote_bash "$host" "$deploy_dir/.env" <<'REMOTE'
if grep -Eq '^COMPOSE_PROFILES=(.*,)?hysteria(,.*)?$' "$1" 2>/dev/null; then
    printf 'true\n'
else
    printf 'false\n'
fi
REMOTE
}

xray_verify() {
    local host="$1" hysteria_enabled="$2"
    local -a containers=(adguard-home warp xray)
    [ "$hysteria_enabled" != true ] || containers+=(hysteria)
    compose_wait_healthy "$host" "${MESH_TIMEOUT:-120}" "${containers[@]}" || return 1
    remote_bash "$host" <<'REMOTE'
sudo docker exec xray python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:9091/health", timeout=4).read()' >/dev/null
REMOTE
}
