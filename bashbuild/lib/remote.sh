#!/usr/bin/env bash
# Remote staging, managed-file promotion, backup, rollback, and locking.

mesh_validate_run_id() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || { error "invalid deployment run id: $1"; return 1; }
}

remote_preflight() {
    local host="$1" deploy_dir="$2"
    mesh_validate_deploy_dir "$deploy_dir" || return 1
    remote_bash "$host" "$deploy_dir" <<'REMOTE'
set -euo pipefail
command -v docker >/dev/null
sudo -n true
sudo docker info >/dev/null
sudo docker compose version >/dev/null
sudo install -d -m 0755 "$1" "$1/.staging" "$1/.backups"
test -w /tmp
REMOTE
}

remote_lock_acquire() {
    local host="$1" deploy_dir="$2" run_id="$3"
    mesh_validate_deploy_dir "$deploy_dir" || return 1
    mesh_validate_run_id "$run_id" || return 1
    remote_bash "$host" "$deploy_dir" "$run_id" <<'REMOTE'
set -euo pipefail
lock_dir="$1/.deploy.lock"
sudo install -d -m 0755 "$1"
if ! sudo mkdir "$lock_dir" 2>/dev/null; then
    printf 'deployment lock already held: %s\n' "$lock_dir" >&2
    sudo cat "$lock_dir/run-id" 2>/dev/null >&2 || true
    exit 1
fi
printf '%s\n' "$2" | sudo tee "$lock_dir/run-id" >/dev/null
REMOTE
}

remote_lock_release() {
    local host="$1" deploy_dir="$2" run_id="$3"
    remote_bash "$host" "$deploy_dir" "$run_id" <<'REMOTE'
set -euo pipefail
lock_dir="$1/.deploy.lock"
owner=$(sudo cat "$lock_dir/run-id" 2>/dev/null || true)
if [ "$owner" = "$2" ]; then
    sudo rm -rf -- "$lock_dir"
else
    printf 'refusing to release lock owned by run %s\n' "$owner" >&2
    exit 1
fi
REMOTE
}

remote_upload_stage() {
    local host="$1" local_stage="$2" deploy_dir="$3" run_id="$4"
    local upload_dir="/tmp/mesh-stage-${run_id}"
    stage_manifest_validate "$local_stage/.mesh-manifest" || return 1

    remote_bash "$host" "$upload_dir" <<'REMOTE' >/dev/null 2>&1 || true
rm -rf -- "$1"
REMOTE
    scp_dir_to "$host" "$local_stage" "$upload_dir" || return 1
    remote_bash "$host" "$upload_dir" "$deploy_dir/.staging/$run_id" <<'REMOTE'
set -euo pipefail
sudo rm -rf -- "$2"
sudo mv "$1" "$2"
sudo chown -R root:root "$2"
REMOTE
}

remote_validate_stage() {
    local host="$1" deploy_dir="$2" run_id="$3"
    remote_bash "$host" "$deploy_dir/.staging/$run_id" <<'REMOTE'
set -euo pipefail
stage=$1
cd "$stage"
if [ -f docker-compose.yml ]; then
    compose_file=docker-compose.yml
elif [ -f compose.yml ]; then
    compose_file=compose.yml
else
    printf 'no Compose file in stage\n' >&2
    exit 1
fi
sudo docker compose -f "$compose_file" config -q
REMOTE
}

remote_managed_digest() {
    local host="$1" deploy_dir="$2"
    remote_bash "$host" "$deploy_dir/.mesh-manifest" <<'REMOTE'
if [ -f "$1" ]; then sha256sum "$1" | awk '{print $1}'; fi
REMOTE
}

remote_backup_managed() {
    local host="$1" deploy_dir="$2" run_id="$3"
    remote_bash "$host" "$deploy_dir" "$run_id" <<'REMOTE'
set -euo pipefail
deploy=$1
backup="$deploy/.backups/$2"
manifest="$deploy/.mesh-manifest"
sudo rm -rf -- "$backup"
sudo install -d -m 0700 "$backup/files"
if [ ! -f "$manifest" ]; then
    exit 0
fi
while IFS="$(printf '\t')" read -r relative mode digest; do
    [ -n "$relative" ] || continue
    case "$relative" in /*|*..*|*//*) exit 1 ;; esac
    if [ -f "$deploy/$relative" ]; then
        sudo install -d -m 0700 "$backup/files/$(dirname "$relative")"
        sudo cp -a "$deploy/$relative" "$backup/files/$relative"
    fi
done < "$manifest"
sudo cp "$manifest" "$backup/.mesh-manifest"
sudo chmod 0600 "$backup/.mesh-manifest"
REMOTE
}

remote_promote_stage() {
    local host="$1" deploy_dir="$2" run_id="$3"
    remote_bash "$host" "$deploy_dir" "$run_id" <<'REMOTE'
set -euo pipefail
deploy=$1
stage="$deploy/.staging/$2"
old_manifest="$deploy/.mesh-manifest"
new_manifest="$stage/.mesh-manifest"
test -f "$new_manifest"

if [ -f "$old_manifest" ]; then
    while IFS="$(printf '\t')" read -r relative mode digest; do
        [ -n "$relative" ] || continue
        case "$relative" in /*|*..*|*//*) exit 1 ;; esac
        sudo rm -f -- "$deploy/$relative"
    done < "$old_manifest"
fi

while IFS="$(printf '\t')" read -r relative mode digest; do
    [ -n "$relative" ] || continue
    case "$relative" in /*|*..*|*//*) exit 1 ;; esac
    test -f "$stage/$relative"
    test ! -L "$stage/$relative"
    sudo install -D -m "$mode" -o root -g root "$stage/$relative" "$deploy/$relative"
done < "$new_manifest"
sudo install -m 0600 -o root -g root "$new_manifest" "$old_manifest"
REMOTE
}

remote_restore_backup() {
    local host="$1" deploy_dir="$2" run_id="$3"
    remote_bash "$host" "$deploy_dir" "$run_id" <<'REMOTE'
set -euo pipefail
deploy=$1
backup="$deploy/.backups/$2"
current_manifest="$deploy/.mesh-manifest"
backup_manifest="$backup/.mesh-manifest"

if [ -f "$current_manifest" ]; then
    while IFS="$(printf '\t')" read -r relative mode digest; do
        [ -n "$relative" ] || continue
        case "$relative" in /*|*..*|*//*) exit 1 ;; esac
        sudo rm -f -- "$deploy/$relative"
    done < "$current_manifest"
fi

if [ -f "$backup_manifest" ]; then
    while IFS="$(printf '\t')" read -r relative mode digest; do
        [ -n "$relative" ] || continue
        case "$relative" in /*|*..*|*//*) exit 1 ;; esac
        test -f "$backup/files/$relative"
        sudo install -D -m "$mode" -o root -g root "$backup/files/$relative" "$deploy/$relative"
    done < "$backup_manifest"
    sudo install -m 0600 -o root -g root "$backup_manifest" "$current_manifest"
else
    sudo rm -f -- "$current_manifest"
fi
REMOTE
}

remote_commit_backup() {
    local host="$1" deploy_dir="$2" run_id="$3"
    remote_bash "$host" "$deploy_dir" "$run_id" <<'REMOTE'
set -euo pipefail
printf '%s\n' "$2" | sudo tee "$1/.last-backup" >/dev/null
sudo chmod 0600 "$1/.last-backup"
sudo rm -rf -- "$1/.staging/$2"
REMOTE
}

remote_cleanup_stage() {
    local host="$1" deploy_dir="$2" run_id="$3" network_suffix="${4:-}"
    remote_bash "$host" "$deploy_dir/.staging/$run_id" "$run_id" "$network_suffix" <<'REMOTE'
sudo rm -rf -- "$1"
if [ -n "$3" ]; then
    network="${2,,}_$3"
    sudo docker network rm "$network" >/dev/null 2>&1 || true
fi
REMOTE
}
