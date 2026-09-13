#!/usr/bin/env bash
# Shared Docker Compose apply and health verification.

compose_apply() {
    local host="$1" deploy_dir="$2" mode="${3:-none}"
    shift 3 || true
    local services=("$@")
    case "$mode" in pull|build|none) ;; *) error "invalid compose apply mode: $mode"; return 1 ;; esac

    remote_bash "$host" "$deploy_dir" "$mode" "${services[@]}" <<'REMOTE'
set -euo pipefail
deploy=$1
mode=$2
shift 2
cd "$deploy"
if [ "$mode" = pull ]; then sudo docker compose pull --quiet "$@"; fi
if [ "$mode" = build ]; then
    sudo docker compose up -d --build --force-recreate --remove-orphans "$@"
else
    sudo docker compose up -d --force-recreate --remove-orphans "$@"
fi
REMOTE
}

compose_wait_healthy() {
    local host="$1" timeout="$2"
    shift 2
    local containers=("$@")
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || { error "invalid health timeout: $timeout"; return 1; }
    [ "${#containers[@]}" -gt 0 ] || { error "at least one container is required"; return 1; }

    remote_bash "$host" "$timeout" "${containers[@]}" <<'REMOTE'
set -euo pipefail
timeout=$1
shift
deadline=$((SECONDS + timeout))
while [ "$SECONDS" -lt "$deadline" ]; do
    all_healthy=true
    for container in "$@"; do
        state=$(sudo docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)
        case "$state" in "running healthy"|"running none") ;; *) all_healthy=false; break ;; esac
    done
    [ "$all_healthy" = true ] && exit 0
    sleep 2
done
printf 'containers did not become healthy within %ss: %s\n' "$timeout" "$*" >&2
exit 1
REMOTE
}

deployment_summary() {
    local component="$1" target="$2" result="$3" digest="${4:-unknown}"
    log "DEPLOY" "component=$component target=$target result=$result digest=$digest"
}
