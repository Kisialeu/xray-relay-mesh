#!/usr/bin/env bash

xray_render_stage() {
    local inventory="$1" node="$2" stage_dir="$3"
    local hysteria_enabled
    hysteria_enabled=$(inv_node_has_hysteria "$inventory" "$node")

    mkdir -p "$stage_dir/config" "$stage_dir/adguard/conf" "$stage_dir/system"
    render_xray_env "$inventory" "$node" > "$stage_dir/.env"
    render_hysteria_env "$inventory" "$node" >> "$stage_dir/.env"
    render_xray_config_json "$inventory" "$node" > "$stage_dir/config/config.json"
    render_adguard_yaml "$inventory" > "$stage_dir/adguard/conf/AdGuardHome.yaml"
    cp "$MESH_DIR/services/xray/entrypoint.sh" "$stage_dir/entrypoint.sh"
    cp "$MESH_DIR/services/xray/stats.py" "$stage_dir/stats.py"
    cp "$MESH_DIR/services/xray/compose.yml" "$stage_dir/docker-compose.yml"
    cp "$MESH_DIR/services/xray/xray-logrotate.conf" "$stage_dir/system/xray-logrotate.conf"
    cp "$MESH_DIR/services/xray/xray-restart.cron" "$stage_dir/system/xray-restart.cron"

    if [ "$hysteria_enabled" = true ]; then
        mkdir -p "$stage_dir/hysteria"
        render_hysteria_config "$inventory" "$node" > "$stage_dir/hysteria/config.yaml"
        chmod 0600 "$stage_dir/hysteria/config.yaml"
    fi

    chmod 0600 "$stage_dir/.env" "$stage_dir/config/config.json"
    chmod 0644 \
        "$stage_dir/adguard/conf/AdGuardHome.yaml" \
        "$stage_dir/docker-compose.yml" \
        "$stage_dir/stats.py" \
        "$stage_dir/system/xray-logrotate.conf" \
        "$stage_dir/system/xray-restart.cron"
    chmod 0755 "$stage_dir/entrypoint.sh"
    stage_write_manifest "$stage_dir"
}
