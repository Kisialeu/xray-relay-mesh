#!/usr/bin/env bash

set -euo pipefail

COMPONENT_XRAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "$COMPONENT_XRAY_DIR/../../lib/common.sh"
# shellcheck source=../../lib/inventory.sh
source "$COMPONENT_XRAY_DIR/../../lib/inventory.sh"
# shellcheck source=../../lib/stage.sh
source "$COMPONENT_XRAY_DIR/../../lib/stage.sh"
# shellcheck source=../../lib/remote.sh
source "$COMPONENT_XRAY_DIR/../../lib/remote.sh"
# shellcheck source=../../lib/compose.sh
source "$COMPONENT_XRAY_DIR/../../lib/compose.sh"
# shellcheck source=render.sh
source "$COMPONENT_XRAY_DIR/render.sh"
# shellcheck source=hysteria_render.sh
source "$COMPONENT_XRAY_DIR/hysteria_render.sh"
# shellcheck source=stage.sh
source "$COMPONENT_XRAY_DIR/stage.sh"
# shellcheck source=verify.sh
source "$COMPONENT_XRAY_DIR/verify.sh"

xray_apply_services() {
    local host="$1" deploy_dir="$2" hysteria_enabled="$3" mode="$4"
    local -a services=(adguard-home warp xray)
    [ "$hysteria_enabled" != true ] || services+=(hysteria)
    xray_remove_disabled_hysteria "$host" "$deploy_dir" "$hysteria_enabled" || return 1
    compose_apply "$host" "$deploy_dir" "$mode" "${services[@]}"
}

xray_deploy_one() {
    local inventory="$1" node="$2" host stage_dir="" run_id local_digest remote_digest
    local hysteria_enabled rc=0 changed=1 result
    host=$(inv_node_field "$inventory" "$node" host)
    hysteria_enabled=$(inv_node_has_hysteria "$inventory" "$node")
    mesh_resolve_ssh "$inventory" "$node"
    stage_create stage_dir xray
    xray_render_stage "$inventory" "$node" "$stage_dir"
    jq -e . "$stage_dir/config/config.json" >/dev/null
    local_digest=$(mesh_sha256_file "$stage_dir/.mesh-manifest")
    run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"

    info "$node ($host): deploying Xray transaction $run_id"
    xray_remote_preflight "$host" "$XRAY_DEPLOY_DIR" "$hysteria_enabled" || rc=1
    if [ "$rc" -eq 0 ]; then remote_lock_acquire "$host" "$XRAY_DEPLOY_DIR" "$run_id" || rc=1; fi
    if [ "$rc" -eq 0 ]; then xray_prepare_persistent "$host" "$XRAY_DEPLOY_DIR" "$hysteria_enabled" || rc=1; fi
    if [ "$rc" -eq 0 ]; then remote_upload_stage "$host" "$stage_dir" "$XRAY_DEPLOY_DIR" "$run_id" || rc=1; fi
    if [ "$rc" -eq 0 ]; then xray_validate_stage "$host" "$XRAY_DEPLOY_DIR" "$run_id" "$hysteria_enabled" || rc=1; fi

    if [ "$rc" -eq 0 ]; then
        remote_digest=$(remote_managed_digest "$host" "$XRAY_DEPLOY_DIR" || true)
        if [ "$remote_digest" = "$local_digest" ]; then
            changed=0
            if ! xray_verify "$host" "$hysteria_enabled"; then
                info "$node ($host): Xray is unchanged but not healthy; reconciling"
                xray_apply_services "$host" "$XRAY_DEPLOY_DIR" "$hysteria_enabled" none || rc=1
                [ "$rc" -ne 0 ] || xray_verify "$host" "$hysteria_enabled" || rc=1
            fi
        fi
    fi

    if [ "$rc" -eq 0 ] && [ "$changed" -eq 1 ]; then
        remote_backup_managed "$host" "$XRAY_DEPLOY_DIR" "$run_id" || rc=1
        [ "$rc" -ne 0 ] || remote_promote_stage "$host" "$XRAY_DEPLOY_DIR" "$run_id" || rc=1
        [ "$rc" -ne 0 ] || xray_sync_system_hooks "$host" "$XRAY_DEPLOY_DIR" || rc=1
        [ "$rc" -ne 0 ] || xray_apply_services "$host" "$XRAY_DEPLOY_DIR" "$hysteria_enabled" pull || rc=1
        [ "$rc" -ne 0 ] || xray_verify "$host" "$hysteria_enabled" || rc=1
        if [ "$rc" -ne 0 ]; then
            error "$node ($host): Xray apply failed; restoring managed backup"
            if remote_restore_backup "$host" "$XRAY_DEPLOY_DIR" "$run_id"; then
                hysteria_enabled=$(xray_remote_hysteria_enabled "$host" "$XRAY_DEPLOY_DIR" || printf 'false\n')
                xray_sync_system_hooks "$host" "$XRAY_DEPLOY_DIR" >/dev/null 2>&1 || true
                xray_apply_services "$host" "$XRAY_DEPLOY_DIR" "$hysteria_enabled" none >/dev/null 2>&1 || true
            fi
        else
            remote_commit_backup "$host" "$XRAY_DEPLOY_DIR" "$run_id" || rc=1
        fi
    fi

    remote_cleanup_stage "$host" "$XRAY_DEPLOY_DIR" "$run_id" xray-net >/dev/null 2>&1 || true
    remote_lock_release "$host" "$XRAY_DEPLOY_DIR" "$run_id" >/dev/null 2>&1 || true
    if [ "$rc" -eq 0 ]; then
        if [ "$changed" -eq 0 ]; then result=noop; else result=applied; fi
        deployment_summary xray "$node" "$result" "$local_digest"
    else
        deployment_summary xray "$node" failed "$local_digest"
        alert "Xray deploy FAILED for $node ($host)"
    fi
    stage_cleanup
    return "$rc"
}

xray_deploy_target() {
    local inventory="$1" target="$2" node failed=0
    mesh_check_local_deps
    inv_validate "$inventory" || return 1
    inv_validate_xray_deploy_secrets "$inventory" || return 1
    mesh_validate_deploy_dir "$XRAY_DEPLOY_DIR" || return 1
    if [ "$target" = all ]; then
        while IFS= read -r node; do xray_deploy_one "$inventory" "$node" || failed=1; done < <(inv_node_names "$inventory")
    else
        inv_node_exists "$inventory" "$target" || { error "node '$target' not found in inventory: $inventory"; return 1; }
        xray_deploy_one "$inventory" "$target" || failed=1
    fi
    return "$failed"
}

xray_rollback_one() {
    local inventory="$1" node="$2" host backup_run lock_id hysteria_enabled rc=0
    mesh_check_local_deps
    inv_validate "$inventory" || return 1
    inv_node_exists "$inventory" "$node" || { error "node not found: $node"; return 1; }
    mesh_validate_deploy_dir "$XRAY_DEPLOY_DIR" || return 1
    host=$(inv_node_field "$inventory" "$node" host)
    mesh_resolve_ssh "$inventory" "$node"
    backup_run=$(remote_bash "$host" "$XRAY_DEPLOY_DIR/.last-backup" <<'REMOTE' || true
cat "$1" 2>/dev/null
REMOTE
    )
    [ -n "$backup_run" ] || { error "$node ($host): no managed Xray backup is available"; return 1; }
    lock_id="rollback-$$"
    remote_lock_acquire "$host" "$XRAY_DEPLOY_DIR" "$lock_id" || return 1
    remote_restore_backup "$host" "$XRAY_DEPLOY_DIR" "$backup_run" || rc=1
    if [ "$rc" -eq 0 ]; then
        hysteria_enabled=$(xray_remote_hysteria_enabled "$host" "$XRAY_DEPLOY_DIR") || rc=1
    fi
    [ "$rc" -ne 0 ] || xray_sync_system_hooks "$host" "$XRAY_DEPLOY_DIR" || rc=1
    [ "$rc" -ne 0 ] || xray_apply_services "$host" "$XRAY_DEPLOY_DIR" "$hysteria_enabled" none || rc=1
    [ "$rc" -ne 0 ] || xray_verify "$host" "$hysteria_enabled" || rc=1
    remote_lock_release "$host" "$XRAY_DEPLOY_DIR" "$lock_id" >/dev/null 2>&1 || true
    if [ "$rc" -eq 0 ]; then
        success "$node ($host): Xray rollback completed"
        return 0
    fi
    error "$node ($host): Xray rollback failed"
    return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    [ $# -ge 1 ] || { error "usage: $0 <all|node_name> [inventory.json]"; exit 1; }
    xray_deploy_target "${2:-$MESH_DIR/configs/inventory.json}" "$1"
fi
