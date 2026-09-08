#!/usr/bin/env bash

caddy_render_stage() {
    local inventory="$1" stage_dir="$2" domain origin_secret content_dir
    local profile_title profile_description support_url support_email update_interval app_proxy_enable app_proxy_mode app_proxy_packages
    domain=$(inv_subs_domain "$inventory")
    origin_secret=$(inv_subs_origin_verify_secret "$inventory")
    content_dir=$(inv_subs_content_deploy_dir "$inventory")
    profile_title=$(inv_subs_profile_title "$inventory")
    profile_description=$(inv_subs_profile_description "$inventory")
    support_url=$(inv_subs_support_url "$inventory")
    support_email=$(inv_subs_support_email "$inventory")
    update_interval=$(inv_subs_profile_update_interval "$inventory")
    app_proxy_enable=$(inv_subs_app_proxy_enable "$inventory")
    app_proxy_mode=$(inv_subs_app_proxy_mode "$inventory")
    app_proxy_packages=$(inv_subs_app_proxy_packages "$inventory")

    cp "$MESH_DIR/services/caddy/Caddyfile" "$stage_dir/Caddyfile"
    cp "$MESH_DIR/services/caddy/docker-compose.caddy.yml" "$stage_dir/compose.yml"
    printf 'ORIGIN_VERIFY_SECRET=%s\nSUB_DOMAIN=%s\nSUBS_CONTENT_DIR=%s\nSUB_PROFILE_TITLE=%s\nSUB_PROFILE_DESCRIPTION=%s\nSUB_SUPPORT_URL=%s\nSUB_SUPPORT_EMAIL=%s\nSUB_PROFILE_UPDATE_INTERVAL=%s\nSUB_APP_PROXY_ENABLE=%s\nSUB_APP_PROXY_MODE=%s\nSUB_APP_PROXY_PACKAGES=%s\n' \
        "$origin_secret" "$domain" "$content_dir" "$profile_title" "$profile_description" \
        "$support_url" "$support_email" "$update_interval" "$app_proxy_enable" "$app_proxy_mode" "$app_proxy_packages" > "$stage_dir/.env"
    chmod 0600 "$stage_dir/.env"
    chmod 0644 "$stage_dir/Caddyfile" "$stage_dir/compose.yml"
    stage_write_manifest "$stage_dir"
}
