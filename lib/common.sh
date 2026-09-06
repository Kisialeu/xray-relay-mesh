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

# Installs Docker if missing. Shared by anything deploying a container stack
# (Xray nodes, HAProxy relay, Caddy) - not just one of them.
mesh_check_docker() {
    local host="$1"
    ssh_run "$host" "docker info > /dev/null 2>&1" && return 0

    warn "$host: docker not found - installing..."
    ssh_run "$host" "
        if grep -qi 'amazon linux' /etc/os-release 2>/dev/null || grep -qi 'amzn' /etc/os-release 2>/dev/null; then
            if command -v dnf &>/dev/null; then
                sudo dnf install -y docker && sudo systemctl enable docker && sudo systemctl start docker
            else
                sudo amazon-linux-extras enable docker && sudo yum install -y docker && sudo systemctl enable docker && sudo systemctl start docker
            fi
        else
            curl -fsSL https://get.docker.com | sh && sudo systemctl enable docker && sudo systemctl start docker
        fi
    " || { error "$host: docker installation failed"; return 1; }
}

mesh_check_docker_compose() {
    local host="$1"
    ssh_run "$host" "docker compose version > /dev/null 2>&1" && return 0

    warn "$host: docker compose plugin not found - installing..."
    ssh_run "$host" "
        if command -v apt &>/dev/null; then
            apt install -y docker-compose-plugin > /dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y docker-compose-plugin > /dev/null 2>&1
        elif command -v yum &>/dev/null; then
            sudo yum install -y docker-compose-plugin > /dev/null 2>&1
        else
            echo 'unsupported package manager for docker-compose-plugin' >&2
            exit 1
        fi
    " || { error "$host: docker compose plugin installation failed"; return 1; }
}

mesh_container_running() {
    local host="$1" name="$2"
    local status
    status=$(ssh_run "$host" "docker inspect -f '{{.State.Status}}' ${name} 2>/dev/null" || true)
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

# Single source of truth for the connection options every ssh/scp/rsync call
# uses (rsync needs this as a string for its own -e flag, so it's exposed as
# a function rather than inlined only into ssh_run/scp_to below).
mesh_ssh_opt() {
    printf '%s' "-i $SSH_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
}

ssh_run() {
    local host="$1"; shift
    # shellcheck disable=SC2046
    ssh -n $(mesh_ssh_opt) "$SSH_USER@$host" "$@"
}

scp_to() {
    local host="$1" local_path="$2" remote_path="$3"
    # shellcheck disable=SC2046
    scp $(mesh_ssh_opt) -q "$local_path" "$SSH_USER@${host}:${remote_path}"
}

scp_dir_to() {
    local host="$1" local_dir="$2" remote_path="$3"
    # shellcheck disable=SC2046
    scp -r $(mesh_ssh_opt) -q "$local_dir" "$SSH_USER@${host}:${remote_path}"
}

# Uploads local file $2 to $host, landing at privileged path $3 (parent dirs
# like /opt/* are typically root-owned, so the ssh_user alone often can't
# write there - e.g. a non-root ssh_user like "ubuntu"). Stages via /tmp
# (always writable) then `sudo mv`. Self-heals if $3 currently exists as
# something other than a regular file - e.g. a directory Docker's `-v`
# auto-created when an earlier unchecked upload silently failed to land.
# Force-chmod 644 after the move: `mktemp` (the usual source of $local_path)
# always creates plain files as mode 600, which `scp`/`mv` would otherwise
# carry straight through - leaving the file unreadable by whatever (often
# non-root) UID the container that needs it actually runs as.
# Checks every step; never leaves $3 half-written on failure.
mesh_upload_file() {
    local host="$1" local_path="$2" remote_path="$3"
    local tmp_path
    tmp_path="/tmp/mesh_upload_$$_$(basename "$remote_path")"

    scp_to "$host" "$local_path" "$tmp_path" \
        || { error "$host: failed to upload $(basename "$remote_path") to /tmp"; return 1; }

    ssh_run "$host" "
        set -e
        sudo mkdir -p \"\$(dirname '$remote_path')\"
        if [ -e '$remote_path' ] && [ ! -f '$remote_path' ]; then sudo rm -rf '$remote_path'; fi
        sudo mv '$tmp_path' '$remote_path'
        sudo chmod 644 '$remote_path'
    " || { error "$host: failed to install $remote_path"; ssh_run "$host" "rm -f '$tmp_path'" >/dev/null 2>&1; return 1; }
}

# Uploads local directory $2's contents to $host, merged into privileged
# directory $3 (created with sudo if missing). Same /tmp-staging rationale
# as mesh_upload_file: $3's parent is typically root-owned. Existing files
# under $3 not present in $2 are left untouched (merge, not mirror).
mesh_upload_dir_merge() {
    local host="$1" local_dir="$2" dest_dir="$3"
    local tmp_dir
    tmp_dir="/tmp/mesh_upload_$$_$(basename "$dest_dir")"

    ssh_run "$host" "rm -rf '$tmp_dir'" >/dev/null 2>&1 || true
    scp_dir_to "$host" "$local_dir" "$tmp_dir" \
        || { error "$host: failed to upload staged files to /tmp"; return 1; }

    ssh_run "$host" "
        set -e
        sudo mkdir -p '$dest_dir'
        sudo cp -a '$tmp_dir'/. '$dest_dir'/
        rm -rf '$tmp_dir'
    " || { error "$host: failed to merge staged files into $dest_dir"; ssh_run "$host" "rm -rf '$tmp_dir'" >/dev/null 2>&1; return 1; }
}
