#!/usr/bin/env bash
# Remote-side HAProxy validate/apply/rollback operations over SSH.
# Sourced by other relay-mesh/*.sh scripts - not meant to be run directly.

# Validates a staged cfg file already sitting on $host at $remote_path via an
# ephemeral haproxy container. Never touches the running config/container.
haproxy_validate_remote() {
    local host="$1" remote_path="$2"
    ssh_run "$host" "docker run --rm -v ${remote_path}:/usr/local/etc/haproxy/haproxy.cfg:ro haproxy:alpine haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg"
}

haproxy_remote_sha() {
    local host="$1" remote_path="$2"
    ssh_run "$host" "sha256sum ${remote_path} 2>/dev/null | awk '{print \$1}'"
}

haproxy_remote_file_exists() {
    local host="$1" remote_path="$2"
    ssh_run "$host" "test -f ${remote_path}"
}

haproxy_container_running() { mesh_container_running "$1" "xray-relay"; }

haproxy_reload() {
    local host="$1" deploy_dir="$2"
    ssh_run "$host" "cd ${deploy_dir} && docker compose up -d --force-recreate xray-relay"
}

# Pushes docker-compose.relay.yml to $host, idempotently (only overwrites if
# content differs). This file is static across every node - only
# config/haproxy.cfg changes when the inventory changes.
haproxy_ensure_compose() {
    local host="$1" deploy_dir="$2" local_compose="$3"
    local remote="${deploy_dir}/docker-compose.yml"
    local staged="${deploy_dir}/docker-compose.yml.new"

    mesh_upload_file "$host" "$local_compose" "$staged" || return 1

    if haproxy_remote_file_exists "$host" "$remote"; then
        local sha_active sha_staged
        sha_active=$(haproxy_remote_sha "$host" "$remote")
        sha_staged=$(haproxy_remote_sha "$host" "$staged")
        if [ "$sha_active" = "$sha_staged" ]; then
            ssh_run "$host" "sudo rm -f ${staged}"
            return 0
        fi
    fi

    ssh_run "$host" "sudo mv ${staged} ${remote}" \
        || { error "$host: failed to promote docker-compose.yml"; return 1; }
    info "$host: docker-compose.yml updated"
}

# Applies a locally-rendered cfg ($local_cfg) to $host, idempotently:
#   - stages it, validates it remotely
#   - skips reload entirely if identical to the currently active cfg (no-op)
#   - on change: backs up the current cfg as .last-good, swaps in the new
#     one, reloads
#   - on any validation/start failure: leaves the running config untouched,
#     discards the staged file, returns non-zero (fail-safe, not fail-open)
haproxy_apply() {
    local host="$1" deploy_dir="$2" local_cfg="$3"
    local cfg_dir="${deploy_dir}/config"
    local active="${cfg_dir}/haproxy.cfg"
    local staged="${cfg_dir}/haproxy.cfg.new"
    local last_good="${cfg_dir}/haproxy.cfg.last-good"

    mesh_upload_file "$host" "$local_cfg" "$staged" || return 1

    if ! haproxy_validate_remote "$host" "$staged"; then
        error "$host: staged haproxy.cfg failed validation - leaving running config untouched"
        ssh_run "$host" "sudo rm -f ${staged}"
        return 1
    fi

    if haproxy_remote_file_exists "$host" "$active"; then
        local sha_active sha_staged
        sha_active=$(haproxy_remote_sha "$host" "$active")
        sha_staged=$(haproxy_remote_sha "$host" "$staged")
        if [ "$sha_active" = "$sha_staged" ]; then
            ssh_run "$host" "sudo rm -f ${staged}"
            if haproxy_container_running "$host"; then
                info "$host: config unchanged - no-op"
                return 0
            fi
            info "$host: config unchanged but container not running - starting"
            haproxy_reload "$host" "$deploy_dir" || return 1
            sleep 3
            if ! haproxy_container_running "$host"; then
                error "$host: xray-relay failed to start"
                return 1
            fi
            success "$host: xray-relay started (config was already up to date)"
            return 0
        fi
        ssh_run "$host" "sudo cp ${active} ${last_good}" \
            || { error "$host: failed to snapshot current haproxy.cfg before swap"; return 1; }
    fi

    ssh_run "$host" "sudo mv ${staged} ${active}" \
        || { error "$host: failed to promote staged haproxy.cfg"; return 1; }

    if ! haproxy_reload "$host" "$deploy_dir"; then
        error "$host: reload command failed - rolling back"
        haproxy_rollback "$host" "$deploy_dir"
        return 1
    fi

    sleep 3
    if ! haproxy_container_running "$host"; then
        error "$host: xray-relay not running after reload - rolling back"
        haproxy_rollback "$host" "$deploy_dir"
        return 1
    fi

    success "$host: haproxy.cfg applied and reloaded"
    return 0
}

# Restores config/haproxy.cfg.last-good over the active config and reloads.
haproxy_rollback() {
    local host="$1" deploy_dir="$2"
    local cfg_dir="${deploy_dir}/config"
    local active="${cfg_dir}/haproxy.cfg"
    local last_good="${cfg_dir}/haproxy.cfg.last-good"

    if ! haproxy_remote_file_exists "$host" "$last_good"; then
        error "$host: no haproxy.cfg.last-good to roll back to"
        return 1
    fi

    if ! haproxy_validate_remote "$host" "$last_good"; then
        error "$host: haproxy.cfg.last-good itself fails validation - manual intervention required"
        return 1
    fi

    ssh_run "$host" "sudo cp ${last_good} ${active}" \
        || { error "$host: failed to restore haproxy.cfg.last-good"; return 1; }
    haproxy_reload "$host" "$deploy_dir"

    sleep 3
    if haproxy_container_running "$host"; then
        success "$host: rolled back to last-known-good config"
        return 0
    fi

    error "$host: rollback reload did not bring xray-relay up - manual intervention required"
    return 1
}
