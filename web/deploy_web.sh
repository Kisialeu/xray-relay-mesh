#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"

INVENTORY="${1:-$MESH_DIR/inventory.json}"
WEB_DEPLOY_DIR="${WEB_DEPLOY_DIR:-/opt/xray-web}"
WEB_BIND="${STATS_WEB_BIND:-0.0.0.0}"
WEB_APP_PORT="${WEB_APP_PORT:-9095}"
DOMAIN="${STATS_WEB_DOMAIN:-$(jq -r '.stats.web_domain // ""' "$INVENTORY")}"
EMAIL="${STATS_WEB_EMAIL:-$(jq -r '.stats.web_email // ""' "$INVENTORY")}"
STATS_TOKEN="$(jq -r '.stats.token // ""' "$INVENTORY")"
HTPASSWD_SOURCE="${WEB_HTPASSWD_SOURCE:-/Users/siarhei/Sources/homeblog/minimal_blog/config/.htpasswd}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

mesh_check_local_deps
inv_validate "$INVENTORY" || exit 1

MASTER_NODE="$(inv_stats_master_node "$INVENTORY")"
[ -n "$MASTER_NODE" ] || { error "stats.master_node is required"; exit 1; }
inv_node_exists "$INVENTORY" "$MASTER_NODE" || { error "stats.master_node not found: $MASTER_NODE"; exit 1; }

HOST="$(inv_node_field "$INVENTORY" "$MASTER_NODE" host)"

mesh_resolve_ssh "$INVENTORY" "$MASTER_NODE"

REMOTE_ENV=""
PRESERVE_REMOTE_ENV=0

env_file_value() {
    local key="$1"
    printf '%s\n' "$REMOTE_ENV" | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

# AWS credentials and the certificate email are deployment-time inputs, not
# required for rebuilding the web stack when a valid remote .env already
# exists. Preserve that file unless all certificate inputs are supplied.
if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ] || [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    REMOTE_ENV="$(ssh_run "$HOST" "sudo cat '$WEB_DEPLOY_DIR/.env' 2>/dev/null" || true)"
    if [ -n "$REMOTE_ENV" ]; then
        PRESERVE_REMOTE_ENV=1
        REMOTE_DOMAIN="$(env_file_value STATS_WEB_DOMAIN)"
        REMOTE_EMAIL="$(env_file_value STATS_WEB_EMAIL)"
        [ -n "$REMOTE_DOMAIN" ] && DOMAIN="$REMOTE_DOMAIN"
        [ -n "$REMOTE_EMAIL" ] && EMAIL="$REMOTE_EMAIL"
        info "$MASTER_NODE: preserving existing remote web .env"
    fi
fi

WEB_PORT="$(inv_stats_web_port "$INVENTORY")"
APP_PORT="${STATS_APP_PORT:-$(inv_stats_app_port "$INVENTORY")}"

[[ "$WEB_PORT" =~ ^[0-9]+$ && "$WEB_PORT" -ge 1 && "$WEB_PORT" -le 65535 ]] \
    || { error "stats.web_port must be a port in range 1-65535"; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ && "$APP_PORT" -ge 1 && "$APP_PORT" -le 65535 ]] \
    || { error "stats.app_port must be a port in range 1-65535"; exit 1; }
[ "$APP_PORT" != "$WEB_PORT" ] || { error "stats.app_port and stats.web_port must differ"; exit 1; }
[[ "$WEB_APP_PORT" =~ ^[0-9]+$ && "$WEB_APP_PORT" -ge 1 && "$WEB_APP_PORT" -le 65535 ]] \
    || { error "WEB_APP_PORT must be a port in range 1-65535"; exit 1; }
[ "$WEB_APP_PORT" != "$WEB_PORT" ] && [ "$WEB_APP_PORT" != "$APP_PORT" ] \
    || { error "WEB_APP_PORT must differ from stats.web_port and stats.app_port"; exit 1; }
[ -n "$DOMAIN" ] || { error "stats.web_domain or STATS_WEB_DOMAIN is required"; exit 1; }
[ -n "$EMAIL" ] || { error "stats.web_email or STATS_WEB_EMAIL is required"; exit 1; }
[ -n "$STATS_TOKEN" ] || { error "stats.token is required"; exit 1; }
[ -r "$HTPASSWD_SOURCE" ] || { error "htpasswd file is not readable: $HTPASSWD_SOURCE"; exit 1; }
[ "$PRESERVE_REMOTE_ENV" -eq 1 ] || {
    [ -n "$AWS_ACCESS_KEY_ID" ] || { error "AWS_ACCESS_KEY_ID is required for the first deployment or .env replacement"; exit 1; }
    [ -n "$AWS_SECRET_ACCESS_KEY" ] || { error "AWS_SECRET_ACCESS_KEY is required for the first deployment or .env replacement"; exit 1; }
}

mesh_check_docker "$HOST"
mesh_check_docker_compose "$HOST"
mesh_container_running "$HOST" xray-stats \
    || { error "$MASTER_NODE: xray-stats backend is not running; deploy it first with ./mesh.sh deploy-stats"; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/certbot"
cp "$SCRIPT_DIR/docker-compose.web.yml" "$stage/docker-compose.yml"
cp "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/Nginx.Dockerfile" "$SCRIPT_DIR/requirements.txt" "$SCRIPT_DIR/nginx-cert-watch.sh" "$stage/"
cp "$SCRIPT_DIR/certbot/Dockerfile" "$stage/certbot/"
cp -r "$SCRIPT_DIR/app" "$stage/"
cp "$HTPASSWD_SOURCE" "$stage/htpasswd"
chmod 600 "$stage/htpasswd"
sed \
    -e "s|__STATS_WEB_BIND__|$WEB_BIND|g" \
    -e "s|__STATS_WEB_PORT__|$WEB_PORT|g" \
    -e "s|__STATS_APP_PORT__|$APP_PORT|g" \
    -e "s|__WEB_APP_PORT__|$WEB_APP_PORT|g" \
    -e "s|__STATS_WEB_DOMAIN__|$DOMAIN|g" \
    -e "s|__STATS_API_TOKEN__|$STATS_TOKEN|g" \
    "$SCRIPT_DIR/nginx.conf.template" > "$stage/nginx.conf"

if [ "$PRESERVE_REMOTE_ENV" -eq 0 ]; then
    {
        printf 'STATS_WEB_BIND=%s\n' "$WEB_BIND"
        printf 'STATS_WEB_PORT=%s\n' "$WEB_PORT"
        printf 'WEB_APP_BIND=127.0.0.1\n'
        printf 'WEB_APP_PORT=%s\n' "$WEB_APP_PORT"
        printf 'STATS_WEB_DOMAIN=%s\n' "$DOMAIN"
        printf 'STATS_WEB_EMAIL=%s\n' "$EMAIL"
        printf 'AWS_ACCESS_KEY_ID=%s\n' "$AWS_ACCESS_KEY_ID"
        printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$AWS_SECRET_ACCESS_KEY"
        printf 'AWS_SESSION_TOKEN=%s\n' "$AWS_SESSION_TOKEN"
        printf 'AWS_DEFAULT_REGION=%s\n' "$AWS_DEFAULT_REGION"
    } > "$stage/.env"
fi

info "$MASTER_NODE ($HOST): deploying stats web server"
mesh_upload_dir_merge "$HOST" "$stage" "$WEB_DEPLOY_DIR"
ssh_run "$HOST" "sudo install -d -m 755 '$WEB_DEPLOY_DIR/letsencrypt'"
ssh_run "$HOST" "sudo chmod 600 '$WEB_DEPLOY_DIR/.env'"
ssh_run "$HOST" "sudo chown root:101 '$WEB_DEPLOY_DIR/htpasswd' && sudo chmod 640 '$WEB_DEPLOY_DIR/htpasswd'"
ssh_run "$HOST" "cd '$WEB_DEPLOY_DIR' && docker compose build certbot && docker compose run --rm --entrypoint certbot certbot certonly --dns-route53 --non-interactive --agree-tos --email '$EMAIL' --domain '$DOMAIN' --keep-until-expiring"
ssh_run "$HOST" "cd '$WEB_DEPLOY_DIR' && docker compose build --pull web-app stats-web certbot && docker compose up -d --force-recreate --remove-orphans web-app stats-web certbot"
sleep 2
mesh_container_running "$HOST" xray-stats-web \
    || { error "$MASTER_NODE: stats web container is not running - check docker compose -f '$WEB_DEPLOY_DIR/docker-compose.yml' logs stats-web"; exit 1; }
mesh_container_running "$HOST" xray-web-app \
    || { error "$MASTER_NODE: terminal web container is not running - check docker compose -f '$WEB_DEPLOY_DIR/docker-compose.yml' logs web-app"; exit 1; }
success "$MASTER_NODE: stats web server deployed on loopback:$WEB_PORT"
