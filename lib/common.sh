#!/usr/bin/env bash
# Shared logging, ssh/scp helpers and defaults for the mesh deploy tooling.
# Sourced by other relay-mesh/*.sh scripts - not meant to be run directly.

# SSH_USER/SSH_KEY intentionally have no default here - every node must
# declare its own required "ssh_user"/"ssh_key" in inventory.json (enforced
# by inv_validate), read per node by mesh_resolve_ssh(). Export SSH_USER
# and/or SSH_KEY yourself beforehand to force the same value for every node
# regardless of inventory.
SSH_USER_OVERRIDE="${SSH_USER:-}"
SSH_KEY_OVERRIDE="${SSH_KEY:-}"
: "${RELAY_DEPLOY_DIR:=/opt/relay-node}"
: "${XRAY_DEPLOY_DIR:=/opt/xray-node}"
: "${MESH_WEBHOOK_URL:=}"   # optional ntfy.sh/Slack webhook, same convention as probe_subscriptions.sh
MESH_SSH_ARGS=()

# Exposed to scripts that source this file (they read $MESH_DIR for the
# default inventory path). Export so the value is inherited and shellcheck
# (SC2034) recognises the cross-file usage.
MESH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MESH_DIR

# All logging goes to stderr - never stdout, so a function that both logs
# and returns a value via $(...) (e.g. get_zone_id in the certs scripts)
# can't have a log line accidentally captured as part of that value.
log()     { printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}" >&2; }
info()    { log "INFO " "$@"; }
success() { log "OK   " "$@"; }
warn()    { log "WARN " "$@"; }
error()   { log "ERROR" "$@"; }

# Non-fatal alert: logs a warning and, if configured, POSTs to MESH_WEBHOOK_URL.
# Deploy failures must not crash the whole run (fail-safe, not fail-open).
alert() {
    local msg="$1"
    warn "$msg"
    [ -n "$MESH_WEBHOOK_URL" ] && curl -fsS -m 5 -X POST -d "$msg" "$MESH_WEBHOOK_URL" >/dev/null 2>&1
    return 0
}

# Expands a leading "~/" or "~" (inventory.json stores portable paths;
# ssh -i needs them expanded, since it never sees a shell to do it itself).
_mesh_expand_tilde() {
    # shellcheck disable=SC2088  # '~/' is matched literally; the escaped
    # ${1#\~/} strips a leading literal tilde - tilde-in-quotes is intentional.
    case "$1" in
         "~/"*) printf '%s' "${HOME%/}/${1#\~/}" ;;
         "~")   printf '%s' "$HOME" ;;
         *)     printf '%s' "$1" ;;
    esac
}




# Resolves SSH_USER and SSH_KEY for node $2: an explicitly-exported
# SSH_USER/SSH_KEY always wins (captured as *_OVERRIDE before any per-node
# resolution); otherwise node $2's required "ssh_user"/"ssh_key" fields from
# inventory.json. Call once per node, right before any ssh_run/scp_* call.
mesh_resolve_ssh() {
    local file="$1" name="$2"
    if [ -n "$SSH_USER_OVERRIDE" ]; then
        SSH_USER="$SSH_USER_OVERRIDE"
    else
        SSH_USER=$(inv_node_ssh_user "$file" "$name")
    fi
    if [ -n "$SSH_KEY_OVERRIDE" ]; then
        SSH_KEY="$SSH_KEY_OVERRIDE"
    else
        SSH_KEY=$(_mesh_expand_tilde "$(inv_node_ssh_key "$file" "$name")")
    fi
}

# Resolves SSH_USER/SSH_KEY for the Caddy/subs host (inventory.json's "subs"
# block - not a mesh node, so not resolved via mesh_resolve_ssh/inv_node_*).
# Same override precedence as mesh_resolve_ssh.
mesh_resolve_subs_ssh() {
    local file="$1"
    if [ -n "$SSH_USER_OVERRIDE" ]; then
        SSH_USER="$SSH_USER_OVERRIDE"
    else
        SSH_USER=$(inv_subs_ssh_user "$file")
        : "${SSH_USER:=root}"
    fi
    if [ -n "$SSH_KEY_OVERRIDE" ]; then
        SSH_KEY="$SSH_KEY_OVERRIDE"
    else
        SSH_KEY=$(_mesh_expand_tilde "$(inv_subs_ssh_key "$file")")
        : "${SSH_KEY:=$HOME/.ssh/my_custom_key}"
    fi
}

# Deployment preflight is deliberately read-only. Host package installation
# belongs to the explicit bootstrap command.
mesh_check_docker() {
    local host="$1"
    ssh_run "$host" "docker info >/dev/null 2>&1" \
        || { error "$host: Docker is unavailable; run './mesh.sh bootstrap --node <name>'"; return 1; }
}

mesh_check_docker_compose() {
    local host="$1"
    ssh_run "$host" "docker compose version >/dev/null 2>&1" \
        || { error "$host: Docker Compose is unavailable; run './mesh.sh bootstrap --node <name>'"; return 1; }
}

mesh_container_running() {
    local host="$1" name="$2"
    local status
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
        || { error "invalid container name: $name"; return 1; }
    status=$(remote_bash "$host" "$name" <<'REMOTE' || true
docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null
REMOTE
    )
    [ "$status" = "running" ]
}

mesh_check_local_deps() {
    local missing=() cmd
    for cmd in jq ssh scp; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing local dependencies: ${missing[*]}"
        return 1
    fi
}

# Single source of truth for SSH connection options. SSH and SCP consume an
# array so identity paths containing whitespace remain one argument.
mesh_build_ssh_args() {
    MESH_SSH_ARGS=(
        -i "$SSH_KEY"
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new
        -o BatchMode=yes
    )
}

# rsync's -e interface requires one string. Each array element is Bash-quoted
# before joining; callers must pass the result as one argument.
mesh_ssh_opt() {
    local arg output="" quoted
    mesh_build_ssh_args
    for arg in "${MESH_SSH_ARGS[@]}"; do
        printf -v quoted '%q' "$arg"
        output+="${output:+ }$quoted"
    done
    printf '%s' "$output"
}

ssh_run() {
    local host="$1"; shift
    mesh_build_ssh_args
    ssh -n "${MESH_SSH_ARGS[@]}" "$SSH_USER@$host" "$@"
}

scp_to() {
    local host="$1" local_path="$2" remote_path="$3"
    mesh_build_ssh_args
    scp "${MESH_SSH_ARGS[@]}" -q "$local_path" "$SSH_USER@${host}:${remote_path}"
}

scp_dir_to() {
    local host="$1" local_dir="$2" remote_path="$3"
    mesh_build_ssh_args
    scp -r "${MESH_SSH_ARGS[@]}" -q "$local_dir" "$SSH_USER@${host}:${remote_path}"
}

_mesh_shell_quote() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

# Runs a script supplied on stdin and transports all remote values as Bash
# positional parameters. Arguments are single-quote escaped before OpenSSH
# passes the command through the remote login shell.
remote_bash() {
    local host="$1" command="bash -s --" arg
    shift
    for arg in "$@"; do
        command+=" $(_mesh_shell_quote "$arg")"
    done
    mesh_build_ssh_args
    ssh "${MESH_SSH_ARGS[@]}" "$SSH_USER@$host" "$command"
}

mesh_validate_deploy_dir() {
    local path="$1"
    [[ "$path" =~ ^/opt/[A-Za-z0-9._/-]+$ ]] || {
        error "deploy directory must be an absolute path below /opt: $path"
        return 1
    }
    case "$path" in
        /opt|/opt/|*..*|*//*) error "unsafe deploy directory: $path"; return 1 ;;
    esac
}

mesh_validate_file_mode() {
    [[ "$1" =~ ^0?[0-7]{3}$ ]] || { error "invalid file mode: $1"; return 1; }
}

mesh_validate_owner() {
    [[ "$1" =~ ^([A-Za-z_][A-Za-z0-9_.-]*|[0-9]+)$ ]] \
        || { error "invalid owner or group: $1"; return 1; }
}

# Uploads local file $2 to $host, landing at privileged path $3 (parent dirs
# like /opt/* are typically root-owned, so the ssh_user alone often can't
# write there - e.g. a non-root ssh_user like "ubuntu"). Stages via /tmp
# (always writable) then `sudo mv`. Self-heals if $3 currently exists as
# something other than a regular file - e.g. a directory Docker's `-v`
# auto-created when an earlier unchecked upload silently failed to land.
# Mode, owner, and group are mandatory so callers must classify secret files.
# Checks every step; never leaves $3 half-written on failure.
mesh_upload_file() {
    local host="$1" local_path="$2" remote_path="$3" mode="$4" owner="$5" group="$6"
    local tmp_path
    tmp_path="/tmp/mesh_upload_$$_$(basename "$remote_path")"

    [ -f "$local_path" ] || { error "upload source is not a file: $local_path"; return 1; }
    mesh_validate_file_mode "$mode" || return 1
    mesh_validate_owner "$owner" || return 1
    mesh_validate_owner "$group" || return 1

    scp_to "$host" "$local_path" "$tmp_path" \
        || { error "$host: failed to upload $(basename "$remote_path") to /tmp"; return 1; }

    remote_bash "$host" "$tmp_path" "$remote_path" "$mode" "$owner" "$group" <<'REMOTE' || {
set -euo pipefail
tmp_path=$1
remote_path=$2
mode=$3
owner=$4
group=$5
sudo mkdir -p "$(dirname "$remote_path")"
if [ -e "$remote_path" ] && [ ! -f "$remote_path" ]; then
    sudo rm -rf -- "$remote_path"
fi
sudo install -m "$mode" -o "$owner" -g "$group" "$tmp_path" "$remote_path"
rm -f -- "$tmp_path"
REMOTE
        error "$host: failed to install $remote_path"
        remote_bash "$host" "$tmp_path" <<'REMOTE' >/dev/null 2>&1 || true
rm -f -- "$1"
REMOTE
        return 1
    }
}

# Uploads local directory $2's contents to $host, merged into privileged
# directory $3 (created with sudo if missing). Same /tmp-staging rationale
# as mesh_upload_file: $3's parent is typically root-owned. Existing files
# under $3 not present in $2 are left untouched (merge, not mirror).
mesh_upload_dir_merge() {
    local host="$1" local_dir="$2" dest_dir="$3"
    local tmp_dir
    tmp_dir="/tmp/mesh_upload_$$_$(basename "$dest_dir")"

    remote_bash "$host" "$tmp_dir" <<'REMOTE' >/dev/null 2>&1 || true
rm -rf -- "$1"
REMOTE
    scp_dir_to "$host" "$local_dir" "$tmp_dir" \
        || { error "$host: failed to upload staged files to /tmp"; return 1; }

    remote_bash "$host" "$tmp_dir" "$dest_dir" <<'REMOTE' || {
set -euo pipefail
tmp_dir=$1
dest_dir=$2
sudo mkdir -p "$dest_dir"
sudo cp -a "$tmp_dir"/. "$dest_dir"/
rm -rf -- "$tmp_dir"
REMOTE
        error "$host: failed to merge staged files into $dest_dir"
        remote_bash "$host" "$tmp_dir" <<'REMOTE' >/dev/null 2>&1 || true
rm -rf -- "$1"
REMOTE
        return 1
    }
}
