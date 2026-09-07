#!/usr/bin/env bash
# Remote-side Xray node stack operations over SSH: host prep (docker,
# docker compose plugin, BBR, deps), idempotent apply (config + restart only
# on change), and rollback via a tar snapshot of the previous deploy dir.
# deploy_dir (e.g. /opt/xray-node) is typically root-owned, so every write
# under it goes through sudo - the ssh_user (e.g. a non-root "ubuntu") may
# not otherwise have permission.
# Sourced by other relay-mesh/deploy/*.sh scripts - not meant to be run directly.

# Thin aliases over the generic mesh_check_docker*/mesh_container_running in
# common.sh (shared with the relay/Caddy deploy scripts too).
xray_check_docker()         { mesh_check_docker "$1"; }
xray_check_docker_compose() { mesh_check_docker_compose "$1"; }

xray_check_remote_deps() {
    local host="$1"
    ssh_run "$host" "
        if command -v apt &>/dev/null; then
            sudo apt install -y zstd cron > /dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y zstd cronie > /dev/null 2>&1 && sudo systemctl enable --now crond > /dev/null 2>&1 || true
        elif command -v yum &>/dev/null; then
            sudo yum install -y zstd cronie > /dev/null 2>&1 && sudo systemctl enable --now crond > /dev/null 2>&1 || true
        fi
    " || warn "$host: failed to install zstd/cron (log rotation/restart cron may not work)"
}

xray_check_bbr() {
    local host="$1" current
    current=$(ssh_run "$host" "sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null")
    [ "$current" = "bbr" ] && return 0

    ssh_run "$host" "
        sudo modprobe tcp_bbr 2>/dev/null || true
        sudo mkdir -p /etc/modules-load.d /etc/sysctl.d
        grep -qxF 'tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null \
            || echo 'tcp_bbr' | sudo tee -a /etc/modules-load.d/bbr.conf > /dev/null
        sudo sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null
        grep -qxF 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.d/99-bbr.conf 2>/dev/null \
            || echo 'net.ipv4.tcp_congestion_control=bbr' | sudo tee -a /etc/sysctl.d/99-bbr.conf > /dev/null
    " >/dev/null 2>&1

    current=$(ssh_run "$host" "sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null")
    [ "$current" = "bbr" ] || warn "$host: BBR could not be enabled (kernel may not support it)"
}

# Hysteria2 runs over QUIC/UDP, which needs a much bigger UDP socket buffer
# than the Linux default (~208KB) to avoid packet loss under real throughput -
# see https://v2.hysteria.network/docs/advanced/Performance/ (official
# recommendation: 16MB). Only called for nodes with "hysteria" in their
# protocols. A Docker container's network namespace snapshots net.core.*
# at creation time, so an already-running hysteria container won't see a
# freshly-raised host limit until its namespace is recreated - hence the
# force-recreate below, but ONLY if hysteria/config.yaml already exists AS A
# FILE (i.e. this node has run with hysteria enabled before). This check
# runs in the host-prep phase, before deploy_nodes.sh uploads that file - on
# a node enabling hysteria for the very first time, recreating here would
# make Docker Compose auto-create the missing bind-mount source as an empty
# DIRECTORY, permanently blocking every later attempt to write the real file
# there. Skipping the recreate on first-enable is correct anyway: the normal
# apply flow right after this will create that container fresh (since the
# rendered files changed), already picking up the raised sysctl.
xray_check_udp_buffers() {
    local host="$1" deploy_dir="$2" current
    current=$(ssh_run "$host" "sysctl -n net.core.rmem_max 2>/dev/null")
    [ "${current:-0}" -ge 16777216 ] 2>/dev/null && return 0

    ssh_run "$host" "
        sudo mkdir -p /etc/sysctl.d
        sudo sysctl -w net.core.rmem_max=16777216 > /dev/null
        sudo sysctl -w net.core.wmem_max=16777216 > /dev/null
        grep -qxF 'net.core.rmem_max=16777216' /etc/sysctl.d/99-hysteria-udp.conf 2>/dev/null \
            || echo 'net.core.rmem_max=16777216' | sudo tee -a /etc/sysctl.d/99-hysteria-udp.conf > /dev/null
        grep -qxF 'net.core.wmem_max=16777216' /etc/sysctl.d/99-hysteria-udp.conf 2>/dev/null \
            || echo 'net.core.wmem_max=16777216' | sudo tee -a /etc/sysctl.d/99-hysteria-udp.conf > /dev/null
    " >/dev/null 2>&1

    current=$(ssh_run "$host" "sysctl -n net.core.rmem_max 2>/dev/null")
    if [ "${current:-0}" -ge 16777216 ] 2>/dev/null; then
        if ssh_run "$host" "test -f ${deploy_dir}/hysteria/config.yaml" >/dev/null 2>&1; then
            ssh_run "$host" "cd ${deploy_dir} && docker compose --profile hysteria up -d --force-recreate hysteria" >/dev/null 2>&1 \
                || warn "$host: raised UDP buffers but failed to recreate the hysteria container - restart it manually so it picks up the new limit"
        fi
    else
        warn "$host: could not raise net.core.rmem_max/wmem_max for Hysteria2 UDP throughput"
    fi
}

xray_container_running() { mesh_container_running "$1" "$2"; }

# A valid deployment requires every service in the compose stack, not only
# the xray container. This makes an unchanged deploy self-healing after a
# host reboot or a manually stopped dependency. hysteria_enabled is only
# checked when "true" - its container doesn't exist at all otherwise (gated
# by the "hysteria" compose profile), so checking it unconditionally would
# make xray_stack_running never succeed on nodes without Hysteria2.
xray_stack_running() {
    local host="$1" hysteria_enabled="${2:-false}" service
    local services=(adguard-home warp xray)
    [ "$hysteria_enabled" = "true" ] && services+=(hysteria)
    for service in "${services[@]}"; do
        xray_container_running "$host" "$service" || return 1
    done
}

xray_start() {
    local host="$1" deploy_dir="$2" hysteria_enabled="${3:-false}"
    ssh_run "$host" "cd ${deploy_dir} && docker compose pull && docker compose down --remove-orphans && docker compose up -d" || return 1
    sleep 3
    xray_stack_running "$host" "$hysteria_enabled"
}

# Starts only the stopped or absent services. Unlike xray_start(), this keeps
# already-running containers intact when the rendered deployment is unchanged.
xray_ensure_running() {
    local host="$1" deploy_dir="$2" hysteria_enabled="${3:-false}"
    if xray_stack_running "$host" "$hysteria_enabled"; then
        info "$host: xray stack unchanged and running - no-op"
        return 0
    fi

    info "$host: xray stack unchanged but a service is not running - starting it"
    ssh_run "$host" "cd ${deploy_dir} && docker compose up -d --remove-orphans" || return 1
    sleep 3
    xray_stack_running "$host" "$hysteria_enabled"
}

xray_restore_backup() {
    local host="$1" deploy_dir="$2" backup="$3"
    if ! ssh_run "$host" "test -f ${backup}"; then
        error "$host: no backup tarball to restore - manual intervention required"
        return 1
    fi
    ssh_run "$host" "sudo rm -rf ${deploy_dir} && sudo tar xzf ${backup} -C \$(dirname ${deploy_dir})" \
        || { error "$host: failed to extract backup tarball"; return 1; }
    if xray_start "$host" "$deploy_dir"; then
        success "$host: restored previous xray stack from backup"
        return 0
    fi
    error "$host: restore did not bring xray back up - manual intervention required"
    return 1
}

# Applies a locally-staged directory ($stage_dir, mirroring the remote
# deploy_dir layout: .env, config/config.json, adguard/conf/AdGuardHome.yaml,
# entrypoint.sh, stats.py, docker-compose.yml) idempotently:
#   - skips entirely if the staged signature matches deploy_dir/.deployed.sha256
#   - otherwise: snapshots the current deploy_dir as a tarball, merges in the
#     staged files (adguard/work runtime state and logs/ are never touched),
#     restarts the stack, and verifies xray comes up
#   - on any failure: restores the snapshot, restarts from it (fail-safe, not
#     fail-open)
xray_apply() {
    local host="$1" deploy_dir="$2" stage_dir="$3" hysteria_enabled="${4:-false}"
    local marker="${deploy_dir}/.deployed.sha256"
    local backup="${deploy_dir}.backup.tgz"
    local sig remote_sig

    # If Hysteria2 was previously enabled and is now off, the compose file
    # still defines the "hysteria" service (gated by profile) but .env no
    # longer activates it - stop any leftover container so it doesn't run on
    # a stale config/cert after the profile is dropped.
    if [ "$hysteria_enabled" != "true" ]; then
        ssh_run "$host" "cd ${deploy_dir} 2>/dev/null && docker compose --profile hysteria rm -sf hysteria" >/dev/null 2>&1 || true
    fi

    sig=$(find "$stage_dir" -type f -exec sha256sum {} + | awk '{print $1}' | sort | sha256sum | awk '{print $1}')
    remote_sig=$(ssh_run "$host" "cat ${marker} 2>/dev/null" || true)
    if [ "$remote_sig" = "$sig" ]; then
        xray_ensure_running "$host" "$deploy_dir" "$hysteria_enabled" \
            || { error "$host: xray stack did not become fully running"; return 1; }
        return 0
    fi

    ssh_run "$host" "sudo mkdir -p ${deploy_dir}" \
        || { error "$host: failed to create $deploy_dir"; return 1; }
    if ssh_run "$host" "[ -n \"\$(ls -A ${deploy_dir} 2>/dev/null)\" ]"; then
        ssh_run "$host" "sudo tar czf ${backup} -C \$(dirname ${deploy_dir}) \$(basename ${deploy_dir})" \
            || { error "$host: failed to snapshot current xray stack before swap"; return 1; }
    fi

    info "$host: uploading rendered xray stack"
    mesh_upload_dir_merge "$host" "$stage_dir" "$deploy_dir" || return 1

    local hysteria_mkdir="" hysteria_chmod=""
    if [ "$hysteria_enabled" = "true" ]; then
        hysteria_mkdir="${deploy_dir}/hysteria/acme"
        hysteria_chmod="${deploy_dir}/hysteria/config.yaml"
    fi
    ssh_run "$host" "
        sudo mkdir -p ${deploy_dir}/logs ${deploy_dir}/adguard/work ${deploy_dir}/adguard/conf ${hysteria_mkdir} &&
        sudo chmod 644 ${deploy_dir}/logs &&
        sudo chmod +x ${deploy_dir}/entrypoint.sh &&
        sudo chmod 644 ${deploy_dir}/.env ${deploy_dir}/config/config.json ${deploy_dir}/adguard/conf/AdGuardHome.yaml ${deploy_dir}/docker-compose.yml ${deploy_dir}/stats.py ${hysteria_chmod}
    " || { error "$host: failed to finalize permissions on $deploy_dir"; return 1; }

    if ! xray_start "$host" "$deploy_dir" "$hysteria_enabled"; then
        error "$host: xray stack failed to start - rolling back"
        xray_restore_backup "$host" "$deploy_dir" "$backup"
        return 1
    fi

    ssh_run "$host" "echo '${sig}' | sudo tee ${marker} > /dev/null"
    success "$host: xray stack applied and running"
}

# Installs /etc/logrotate.d/xray and the restart cron job. Both are tiny,
# static, system-level files - rewritten unconditionally (cheap, idempotent).
xray_install_system_files() {
    local host="$1" logrotate_local="$2"
    mesh_upload_file "$host" "$logrotate_local" "/etc/logrotate.d/xray" || return 1
    ssh_run "$host" "sudo chmod 644 /etc/logrotate.d/xray"
    ssh_run "$host" "echo '0 */12 * * * root docker restart warp xray >> /var/log/xray-restart.log 2>&1' | sudo tee /etc/cron.d/xray-restart > /dev/null && sudo chmod 644 /etc/cron.d/xray-restart"
}
