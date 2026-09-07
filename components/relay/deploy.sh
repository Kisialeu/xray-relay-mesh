#!/usr/bin/env bash

COMPONENT_RELAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/stage.sh
source "$COMPONENT_RELAY_DIR/../../lib/stage.sh"
# shellcheck source=../../lib/remote.sh
source "$COMPONENT_RELAY_DIR/../../lib/remote.sh"
# shellcheck source=../../lib/compose.sh
source "$COMPONENT_RELAY_DIR/../../lib/compose.sh"
# shellcheck source=../../relay/lib/render.sh
source "$COMPONENT_RELAY_DIR/../../relay/lib/render.sh"
# shellcheck source=../../relay/lib/haproxy_ctl.sh
source "$COMPONENT_RELAY_DIR/../../relay/lib/haproxy_ctl.sh"
# shellcheck source=render.sh
source "$COMPONENT_RELAY_DIR/render.sh"
# shellcheck source=verify.sh
source "$COMPONENT_RELAY_DIR/verify.sh"

relay_deploy_one() {
    local inventory="$1" node="$2" host stage_dir="" run_id local_digest remote_digest rc=0 changed=1 result
    host="$(inv_node_field "$inventory" "$node" host)"
    mesh_resolve_ssh "$inventory" "$node"
    stage_create stage_dir relay
    relay_render_stage "$inventory" "$node" "$stage_dir"
    local_digest="$(mesh_sha256_file "$stage_dir/.mesh-manifest")"
    run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"

    info "$node ($host): deploying relay transaction $run_id"
    remote_preflight "$host" "$RELAY_DEPLOY_DIR" || rc=1
    if [ "$rc" -eq 0 ]; then remote_lock_acquire "$host" "$RELAY_DEPLOY_DIR" "$run_id" || rc=1; fi
    if [ "$rc" -eq 0 ]; then remote_upload_stage "$host" "$stage_dir" "$RELAY_DEPLOY_DIR" "$run_id" || rc=1; fi
    if [ "$rc" -eq 0 ]; then relay_validate_stage "$host" "$RELAY_DEPLOY_DIR" "$run_id" || rc=1; fi

    if [ "$rc" -eq 0 ]; then
        remote_digest="$(remote_managed_digest "$host" "$RELAY_DEPLOY_DIR" || true)"
        if [ "$remote_digest" = "$local_digest" ]; then
            changed=0
            if ! relay_verify "$host" "$inventory"; then
                info "$node ($host): relay is unchanged but not healthy; reconciling"
                compose_apply "$host" "$RELAY_DEPLOY_DIR" none xray-relay || rc=1
                [ "$rc" -ne 0 ] || relay_verify "$host" "$inventory" || rc=1
            fi
        fi
    fi

    if [ "$rc" -eq 0 ] && [ "$changed" -eq 1 ]; then
        remote_backup_managed "$host" "$RELAY_DEPLOY_DIR" "$run_id" || rc=1
        [ "$rc" -ne 0 ] || remote_promote_stage "$host" "$RELAY_DEPLOY_DIR" "$run_id" || rc=1
        [ "$rc" -ne 0 ] || compose_apply "$host" "$RELAY_DEPLOY_DIR" pull xray-relay || rc=1
        [ "$rc" -ne 0 ] || relay_verify "$host" "$inventory" || rc=1
        if [ "$rc" -ne 0 ]; then
            error "$node ($host): relay apply failed; restoring managed backup"
            remote_restore_backup "$host" "$RELAY_DEPLOY_DIR" "$run_id" || true
            compose_apply "$host" "$RELAY_DEPLOY_DIR" none xray-relay >/dev/null 2>&1 || true
        else
            remote_commit_backup "$host" "$RELAY_DEPLOY_DIR" "$run_id" || rc=1
        fi
    fi

    if [ "$(inv_stats_expose_haproxy "$inventory")" = true ] && [ "$rc" -eq 0 ]; then
        haproxy_apply_stats_firewall "$host" "$(inv_stats_public_port "$inventory")" "$(inv_stats_allowed_sources "$inventory")" || rc=1
    fi

    remote_cleanup_stage "$host" "$RELAY_DEPLOY_DIR" "$run_id" >/dev/null 2>&1 || true
    remote_lock_release "$host" "$RELAY_DEPLOY_DIR" "$run_id" >/dev/null 2>&1 || true
    if [ "$rc" -eq 0 ]; then
        if [ "$changed" -eq 0 ]; then result=noop; else result=applied; fi
        deployment_summary relay "$node" "$result" "$local_digest"
    else
        deployment_summary relay "$node" failed "$local_digest"
        alert "relay deploy FAILED for $node ($host)"
    fi
    stage_cleanup
    return "$rc"
}

relay_deploy_target() {
    local inventory="$1" target="$2" node failed=0
    mesh_check_local_deps
    inv_validate "$inventory" || return 1
    mesh_validate_deploy_dir "$RELAY_DEPLOY_DIR" || return 1
    if [ "$target" = all ]; then
        while IFS= read -r node; do relay_deploy_one "$inventory" "$node" || failed=1; done < <(inv_node_names "$inventory")
    else
        inv_node_exists "$inventory" "$target" || { error "node '$target' not found in inventory: $inventory"; return 1; }
        relay_deploy_one "$inventory" "$target" || failed=1
    fi
    return "$failed"
}

relay_rollback_one() {
    local inventory="$1" node="$2" host run_id lock_id
    mesh_check_local_deps
    inv_validate "$inventory" || return 1
    inv_node_exists "$inventory" "$node" || { error "node not found: $node"; return 1; }
    mesh_validate_deploy_dir "$RELAY_DEPLOY_DIR" || return 1
    host="$(inv_node_field "$inventory" "$node" host)"
    mesh_resolve_ssh "$inventory" "$node"
    run_id="$(remote_bash "$host" "$RELAY_DEPLOY_DIR/.last-backup" <<'REMOTE' || true
cat "$1" 2>/dev/null
REMOTE
    )"
    if [ -z "$run_id" ]; then
        warn "$node ($host): no managed backup pointer; trying legacy relay rollback"
        haproxy_rollback "$host" "$RELAY_DEPLOY_DIR"
        return
    fi
    lock_id="rollback-$$"
    remote_lock_acquire "$host" "$RELAY_DEPLOY_DIR" "$lock_id" || return 1
    if remote_restore_backup "$host" "$RELAY_DEPLOY_DIR" "$run_id" \
        && compose_apply "$host" "$RELAY_DEPLOY_DIR" none xray-relay \
        && relay_verify "$host" "$inventory"; then
        remote_lock_release "$host" "$RELAY_DEPLOY_DIR" "$lock_id" || true
        success "$node ($host): relay rollback completed"
        return 0
    fi
    remote_lock_release "$host" "$RELAY_DEPLOY_DIR" "$lock_id" || true
    error "$node ($host): relay rollback failed"
    return 1
}
