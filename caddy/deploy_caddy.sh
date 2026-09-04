#!/usr/bin/env bash
# Deploys (or updates) the Caddy subscription server on inventory.json's
# subs.caddy_host: installs Docker if missing, uploads Caddyfile + .env +
# compose.yml, starts/recreates the container. Run this BEFORE
# subs/sync_subscriptions.sh on a fresh caddy_host - sync only pushes
# subscription content, it doesn't stand Caddy up.
#
# Ported from the old deploy.sh's deploy_caddy()/sync_and_start_caddy()
# "start" branch - domain/secret now come from inventory.json instead of
# CLI args/env vars (see certs/setup_cdn_cert.sh for the matching CDN setup).
#
# Usage: relay-mesh/caddy/deploy_caddy.sh [inventory.json]
#
# Optional env:
#   ORIGIN_VERIFY_SECRET  - overrides inventory.json's subs.origin_verify_secret
#   SSH_KEY, SSH_USER     - override inventory.json's subs.ssh_key/subs.ssh_user

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"

INVENTORY="${1:-$MESH_DIR/inventory.json}"

mesh_check_local_deps
inv_validate "$INVENTORY" || exit 1

CADDY_HOST="$(inv_subs_caddy_host "$INVENTORY")"
[ -n "$CADDY_HOST" ] || { error "subs.caddy_host not set in $INVENTORY"; exit 1; }
CADDY_DEPLOY_DIR="$(inv_subs_caddy_deploy_dir "$INVENTORY")"
SUB_DOMAIN="$(inv_subs_domain "$INVENTORY")"
[ -n "$SUB_DOMAIN" ] || { error "subs.domain not set in $INVENTORY"; exit 1; }

: "${ORIGIN_VERIFY_SECRET:=$(inv_subs_origin_verify_secret "$INVENTORY")}"
[ -n "$ORIGIN_VERIFY_SECRET" ] || { error "subs.origin_verify_secret not set in $INVENTORY (or export ORIGIN_VERIFY_SECRET)"; exit 1; }

mesh_resolve_subs_ssh "$INVENTORY"

info "$CADDY_HOST: preparing host"
mesh_check_docker "$CADDY_HOST" || exit 1
mesh_check_docker_compose "$CADDY_HOST" || exit 1

ssh_run "$CADDY_HOST" "sudo mkdir -p ${CADDY_DEPLOY_DIR}/subs" \
    || { error "$CADDY_HOST: failed to create $CADDY_DEPLOY_DIR"; exit 1; }

info "$CADDY_HOST: uploading Caddyfile + compose.yml + .env"
mesh_upload_file "$CADDY_HOST" "$SCRIPT_DIR/Caddyfile" "${CADDY_DEPLOY_DIR}/Caddyfile" || exit 1
mesh_upload_file "$CADDY_HOST" "$SCRIPT_DIR/docker-compose.caddy.yml" "${CADDY_DEPLOY_DIR}/compose.yml" || exit 1

ENV_TMP="$(mktemp)"
printf 'ORIGIN_VERIFY_SECRET=%s\nSUB_DOMAIN=%s\n' "$ORIGIN_VERIFY_SECRET" "$SUB_DOMAIN" > "$ENV_TMP"
mesh_upload_file "$CADDY_HOST" "$ENV_TMP" "${CADDY_DEPLOY_DIR}/.env" || { rm -f "$ENV_TMP"; exit 1; }
rm -f "$ENV_TMP"

info "$CADDY_HOST: starting/reloading Caddy"
if mesh_container_running "$CADDY_HOST" "caddy-subs"; then
    ssh_run "$CADDY_HOST" "cd ${CADDY_DEPLOY_DIR} && docker compose up -d --force-recreate" \
        || { error "$CADDY_HOST: failed to recreate Caddy"; exit 1; }
else
    ssh_run "$CADDY_HOST" "cd ${CADDY_DEPLOY_DIR} && docker compose pull && docker compose up -d" \
        || { error "$CADDY_HOST: failed to start Caddy"; exit 1; }
fi

sleep 3
if ! mesh_container_running "$CADDY_HOST" "caddy-subs"; then
    error "$CADDY_HOST: Caddy failed to start - check: ssh ${SSH_USER}@${CADDY_HOST} 'docker compose -f ${CADDY_DEPLOY_DIR}/compose.yml logs caddy-subs'"
    exit 1
fi

success "$CADDY_HOST: Caddy running on :8080 ($CADDY_DEPLOY_DIR)"
info "Next: relay-mesh/subs/generate_subscriptions.sh then subs/sync_subscriptions.sh"
