#!/usr/bin/env bash

subscriptions_render_stage() {
    local source_dir="$1" stage_dir="$2" user_dir token count=0
    for user_dir in "$source_dir"/*/; do
        [ -f "${user_dir}sub.token" ] || continue
        [ -f "${user_dir}sub.b64" ] || { error "generated subscription is incomplete"; return 1; }
        token=$(<"${user_dir}sub.token")
        [[ "$token" =~ ^[0-9a-f]{40}$ ]] || { error "generated subscription contains an invalid token"; return 1; }
        mkdir -p "$stage_dir/$token"
        cp "${user_dir}sub.b64" "$stage_dir/$token/sub.b64"
        if [ -f "${user_dir}sub.url" ]; then
            cp "${user_dir}sub.url" "$stage_dir/$token/sub.url"
        fi
        if [ -f "${user_dir}sub.singbox.json" ]; then
            cp "${user_dir}sub.singbox.json" "$stage_dir/$token/sub.singbox.json"
        fi
        chmod 0644 "$stage_dir/$token/sub.b64"
        [ ! -f "$stage_dir/$token/sub.url" ] || chmod 0644 "$stage_dir/$token/sub.url"
        [ ! -f "$stage_dir/$token/sub.singbox.json" ] || chmod 0644 "$stage_dir/$token/sub.singbox.json"
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || { error "no generated subscriptions were found"; return 1; }
    stage_write_manifest "$stage_dir"
}

subscriptions_validate_stage() {
    local host="$1" deploy_dir="$2" run_id="$3"
    remote_bash "$host" "$deploy_dir/.staging/$run_id/.mesh-manifest" <<'REMOTE'
set -euo pipefail
count=0
while IFS="$(printf '\t')" read -r relative mode digest; do
    [ -n "$relative" ] || continue
    token=${relative%%/*}
    filename=${relative#*/}
    [[ "$token" =~ ^[0-9a-f]{40}$ ]] \
        || { printf 'subscription stage contains an invalid token path\n' >&2; exit 1; }
    [ "$relative" = "$token/$filename" ] \
        || { printf 'subscription stage contains a nested path\n' >&2; exit 1; }
    case "$filename" in
        sub.b64|sub.url|sub.singbox.json) ;;
        *) printf 'subscription stage contains an unexpected managed file\n' >&2; exit 1 ;;
    esac
    [ "$mode" = 644 ] || { printf 'subscription stage contains an invalid file mode\n' >&2; exit 1; }
    count=$((count + 1))
done < "$1"
[ "$count" -gt 0 ]
REMOTE
}

subscriptions_verify_caddy() {
    local host="$1" content_dir="$2"
    remote_bash "$host" "$content_dir" <<'REMOTE'
set -euo pipefail
source_path=$(sudo docker inspect -f '{{range .Mounts}}{{if eq .Destination "/srv/subs"}}{{.Source}}{{end}}{{end}}' caddy-subs 2>/dev/null)
[ "$source_path" = "$1" ]
sudo docker exec caddy-subs wget -qO- http://127.0.0.1:8080/healthz >/dev/null
REMOTE
}

sync_subs_to_caddy() {
    local inventory="$1" source_dir="$2" host content_dir stage_dir="" run_id
    local local_digest remote_digest rc=0 changed=1 result
    host=$(inv_subs_caddy_host "$inventory")
    content_dir=$(inv_subs_content_deploy_dir "$inventory")
    mesh_validate_deploy_dir "$content_dir" || return 1
    stage_create stage_dir subscriptions
    subscriptions_render_stage "$source_dir" "$stage_dir"
    local_digest=$(mesh_sha256_file "$stage_dir/.mesh-manifest")
    run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"

    info "$host: deploying subscription content transaction $run_id"
    remote_preflight "$host" "$content_dir" || rc=1
    if [ "$rc" -eq 0 ]; then remote_lock_acquire "$host" "$content_dir" "$run_id" || rc=1; fi
    if [ "$rc" -eq 0 ]; then remote_upload_stage "$host" "$stage_dir" "$content_dir" "$run_id" || rc=1; fi
    if [ "$rc" -eq 0 ]; then subscriptions_validate_stage "$host" "$content_dir" "$run_id" || rc=1; fi

    if [ "$rc" -eq 0 ]; then
        remote_digest=$(remote_managed_digest "$host" "$content_dir" || true)
        if [ "$remote_digest" = "$local_digest" ]; then
            changed=0
            subscriptions_verify_caddy "$host" "$content_dir" || rc=1
        fi
    fi

    if [ "$rc" -eq 0 ] && [ "$changed" -eq 1 ]; then
        remote_backup_managed "$host" "$content_dir" "$run_id" || rc=1
        [ "$rc" -ne 0 ] || remote_promote_stage "$host" "$content_dir" "$run_id" || rc=1
        [ "$rc" -ne 0 ] || subscriptions_verify_caddy "$host" "$content_dir" || rc=1
        if [ "$rc" -ne 0 ]; then
            error "$host: subscription verification failed; restoring managed backup"
            remote_restore_backup "$host" "$content_dir" "$run_id" || true
        else
            remote_commit_backup "$host" "$content_dir" "$run_id" || rc=1
        fi
    fi

    remote_cleanup_stage "$host" "$content_dir" "$run_id" >/dev/null 2>&1 || true
    remote_lock_release "$host" "$content_dir" "$run_id" >/dev/null 2>&1 || true
    if [ "$rc" -eq 0 ]; then
        if [ "$changed" -eq 0 ]; then result=no_changes; else result=applied; fi
        deployment_summary subscriptions "$host" "$result" "$local_digest"
    else
        deployment_summary subscriptions "$host" failed "$local_digest"
    fi
    stage_cleanup
    return "$rc"
}
