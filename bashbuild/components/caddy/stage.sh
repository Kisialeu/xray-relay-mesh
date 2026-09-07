#!/usr/bin/env bash

caddy_render_stage() {
    local inventory="$1" stage_dir="$2" domain origin_secret content_dir
    domain=$(inv_subs_domain "$inventory")
    origin_secret=$(inv_subs_origin_verify_secret "$inventory")
    content_dir=$(inv_subs_content_deploy_dir "$inventory")

    cp "$MESH_DIR/services/caddy/Caddyfile" "$stage_dir/Caddyfile"
    cp "$MESH_DIR/services/caddy/docker-compose.caddy.yml" "$stage_dir/compose.yml"
    printf 'ORIGIN_VERIFY_SECRET=%s\nSUB_DOMAIN=%s\nSUBS_CONTENT_DIR=%s\n' \
        "$origin_secret" "$domain" "$content_dir" > "$stage_dir/.env"
    chmod 0600 "$stage_dir/.env"
    chmod 0644 "$stage_dir/Caddyfile" "$stage_dir/compose.yml"
    stage_write_manifest "$stage_dir"
}
