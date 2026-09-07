#!/usr/bin/env bash

relay_render_stage() {
    local inventory="$1" node="$2" stage_dir="$3"
    mkdir -p "$stage_dir/config"
    render_haproxy_cfg "$inventory" "$node" > "$stage_dir/config/haproxy.cfg"
    cp "$MESH_DIR/services/relay/compose.yml" "$stage_dir/docker-compose.yml"
    chmod 0644 "$stage_dir/config/haproxy.cfg"
    chmod 0644 "$stage_dir/docker-compose.yml"
    stage_write_manifest "$stage_dir"
}
