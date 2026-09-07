#!/usr/bin/env bash

set -euo pipefail

COMPONENT_CADDY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$COMPONENT_CADDY_DIR/../../lib/common.sh"
# shellcheck source=../../lib/inventory.sh
source "$COMPONENT_CADDY_DIR/../../lib/inventory.sh"
# shellcheck source=../../lib/stage.sh
source "$COMPONENT_CADDY_DIR/../../lib/stage.sh"
# shellcheck source=../../lib/remote.sh
source "$COMPONENT_CADDY_DIR/../../lib/remote.sh"
# shellcheck source=../../lib/compose.sh
source "$COMPONENT_CADDY_DIR/../../lib/compose.sh"
# shellcheck source=stage.sh
source "$COMPONENT_CADDY_DIR/stage.sh"
# shellcheck source=verify.sh
source "$COMPONENT_CADDY_DIR/verify.sh"

caddy_deploy() {
    local inventory="$1" host deploy_dir content_dir stage_dir="" run_id
    local local_digest remote_digest rc=0 changed=1 result
    mesh_check_local_deps
    inv_validate "$inventory" || return 1
    host=$(inv_subs_caddy_host "$inventory")
    deploy_dir=$(inv_subs_caddy_deploy_dir "$inventory")
    content_dir=$(inv_subs_content_deploy_dir "$inventory")
    [ -n "$host" ] || { error "subs.caddy_host is required"; return 1; }
    [ -n "$(inv_subs_domain "$inventory")" ] || { error "subs.domain is required"; return 1; }
    [ -n "$(inv_subs_origin_verify_secret "$inventory")" ] || { error "subs.origin_verify_secret is required"; return 1; }
    mesh_validate_deploy_dir "$deploy_dir" || return 1
    mesh_validate_deploy_dir "$content_dir" || return 1
    mesh_resolve_subs_ssh "$inventory"
    stage_create stage_dir caddy
    caddy_render_stage "$inventory" "$stage_dir"
    local_digest=$(mesh_sha256_file "$stage_dir/.mesh-manifest")
    run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"

    info "$host: deploying Caddy transaction $run_id"
    remote_preflight "$host" "$deploy_dir" || rc=1
    if [ "$rc" -eq 0 ]; then remote_lock_acquire "$host" "$deploy_dir" "$run_id" || rc=1; fi
    if [ "$rc" -eq 0 ]; then caddy_prepare_content_dir "$host" "$content_dir" || rc=1; fi
    if [ "$rc" -eq 0 ]; then remote_upload_stage "$host" "$stage_dir" "$deploy_dir" "$run_id" || rc=1; fi
    if [ "$rc" -eq 0 ]; then caddy_validate_stage "$host" "$deploy_dir" "$run_id" || rc=1; fi

    if [ "$rc" -eq 0 ]; then
        remote_digest=$(remote_managed_digest "$host" "$deploy_dir" || true)
        if [ "$remote_digest" = "$local_digest" ]; then
            changed=0
            if ! caddy_verify "$host"; then
                info "$host: Caddy is unchanged but not healthy; reconciling"
                compose_apply "$host" "$deploy_dir" none caddy-subs || rc=1
                [ "$rc" -ne 0 ] || caddy_verify "$host" || rc=1
            fi
        fi
    fi

    if [ "$rc" -eq 0 ] && [ "$changed" -eq 1 ]; then
        remote_backup_managed "$host" "$deploy_dir" "$run_id" || rc=1
        [ "$rc" -ne 0 ] || remote_promote_stage "$host" "$deploy_dir" "$run_id" || rc=1
        [ "$rc" -ne 0 ] || compose_apply "$host" "$deploy_dir" pull caddy-subs || rc=1
        [ "$rc" -ne 0 ] || caddy_verify "$host" || rc=1
        if [ "$rc" -ne 0 ]; then
            error "$host: Caddy apply failed; restoring managed backup"
            remote_restore_backup "$host" "$deploy_dir" "$run_id" || true
            compose_apply "$host" "$deploy_dir" none caddy-subs >/dev/null 2>&1 || true
        else
            remote_commit_backup "$host" "$deploy_dir" "$run_id" || rc=1
        fi
    fi

    remote_cleanup_stage "$host" "$deploy_dir" "$run_id" >/dev/null 2>&1 || true
    remote_lock_release "$host" "$deploy_dir" "$run_id" >/dev/null 2>&1 || true
    if [ "$rc" -eq 0 ]; then
        if [ "$changed" -eq 0 ]; then result=noop; else result=applied; fi
        deployment_summary caddy "$host" "$result" "$local_digest"
    else
        deployment_summary caddy "$host" failed "$local_digest"
    fi
    stage_cleanup
    return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    caddy_deploy "${1:-$MESH_DIR/configs/inventory.json}"
fi
