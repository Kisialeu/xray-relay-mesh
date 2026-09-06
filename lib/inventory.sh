#!/usr/bin/env bash
# jq-based accessors over an inventory.json file (see relay-mesh/inventory.json).
# Sourced by other relay-mesh/*.sh scripts - not meant to be run directly.

# Validates structure, unique ids/names, whitespace-free names/hosts (both
# get space-delimited-parsed downstream by render.sh/subs_render.sh), that
# every derived relay port (relay_port_base + id) is in range, and that no
# peer's relay port collides with any node that actually binds it: every
# OTHER node binds base+P.id on ITS OWN host (inv_peers_of excludes self),
# so the real collision check is against every other node's direct_port,
# not the port's own node's direct_port. Run before any render/deploy op.
inv_validate() {
    local file="$1"
    [ -f "$file" ] || { error "inventory not found: $file"; return 1; }

    jq -e 'type == "object" and has("nodes") and (.nodes | type == "array") and (.nodes | length > 0)' \
        "$file" >/dev/null 2>&1 || { error "inventory malformed or has no nodes: $file"; return 1; }

    local dup_ids dup_names
    dup_ids=$(jq -r '[.nodes[].id] | group_by(.) | map(select(length > 1)) | flatten | unique | .[]' "$file")
    if [ -n "$dup_ids" ]; then
        error "duplicate node ids in inventory: $dup_ids"
        return 1
    fi

    dup_names=$(jq -r '[.nodes[].name] | group_by(.) | map(select(length > 1)) | flatten | unique | .[]' "$file")
    if [ -n "$dup_names" ]; then
        error "duplicate node names in inventory: $dup_names"
        return 1
    fi

    local whitespace_fields
    whitespace_fields=$(jq -r '.nodes[] | select((.name | test("\\s")) or (.host | test("\\s"))) | .name' "$file")
    if [ -n "$whitespace_fields" ]; then
        error "node name/host must not contain whitespace (parsed space-delimited downstream): $whitespace_fields"
        return 1
    fi

    local base bad
    base=$(inv_relay_port_base "$file")
    bad=$(jq -r --argjson base "$base" '
        .nodes[] | select((($base + .id) < 1) or (($base + .id) > 65535)) | .name
    ' "$file")
    if [ -n "$bad" ]; then
        error "relay port out of range for node(s): $bad"
        return 1
    fi

    local collide
    collide=$(jq -r --argjson base "$base" '
        [ .nodes[] as $x
          | .nodes[]
          | select(.name != $x.name)
          | select(($base + .id) == $x.direct_port)
          | $x.name
        ] | unique | .[]
    ' "$file")
    if [ -n "$collide" ]; then
        error "node(s) whose direct_port collides with a peer's relay port they must bind: $collide"
        return 1
    fi

    local missing_ssh_user missing_ssh_key
    missing_ssh_user=$(jq -r '.nodes[] | select((.ssh_user // "") == "") | .name' "$file")
    if [ -n "$missing_ssh_user" ]; then
        error "node(s) missing required ssh_user field in inventory: $missing_ssh_user"
        return 1
    fi

    missing_ssh_key=$(jq -r '.nodes[] | select((.ssh_key // "") == "") | .name' "$file")
    if [ -n "$missing_ssh_key" ]; then
        error "node(s) missing required ssh_key field in inventory: $missing_ssh_key"
        return 1
    fi

    if [ "$(inv_stats_expose_haproxy "$file")" = "true" ]; then
        local stats_port stats_token stats_rate
        local stats_master stats_pg_password
        stats_port=$(inv_stats_public_port "$file")
        stats_token=$(inv_stats_token "$file")
        stats_rate=$(inv_stats_rate_limit_requests "$file")
        stats_master=$(inv_stats_master_node "$file")
        stats_pg_password=$(inv_stats_postgres_password "$file")

        jq -e --argjson port "$stats_port" '$port >= 1 and $port <= 65535' "$file" >/dev/null 2>&1 \
            || { error "stats.public_port must be in range 1-65535"; return 1; }
        jq -e --argjson rate "$stats_rate" '$rate > 0' "$file" >/dev/null 2>&1 \
            || { error "stats.rate_limit_requests must be a positive number"; return 1; }
        if [ -z "$stats_token" ]; then
            error "stats.expose_via_haproxy=true requires stats.token"
            return 1
        fi
        if [ -z "$stats_master" ]; then
            error "stats.master_node is required"
            return 1
        fi
        if ! inv_node_exists "$file" "$stats_master"; then
            error "stats.master_node not found: $stats_master"
            return 1
        fi
        if [ -z "$stats_pg_password" ]; then
            error "stats.postgres_password is required"
            return 1
        fi
        if ! printf '%s' "$stats_token" | grep -Eq '^[A-Za-z0-9._~:-]{24,}$'; then
            error "stats.token must be at least 24 URL/header-safe characters"
            return 1
        fi
        if ! printf '%s' "$stats_pg_password" | grep -Eq '^[A-Za-z0-9._~:-]{24,}$'; then
            error "stats.postgres_password must be at least 24 URL/header-safe characters"
            return 1
        fi
        local bad_source
        bad_source=$(jq -r '
            .stats.allowed_sources // []
            | .[]
            | select(test("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/[0-9]{1,2})?$") | not)
        ' "$file")
        if [ -n "$bad_source" ]; then
            error "stats.allowed_sources currently supports IPv4 CIDR sources only: $bad_source"
            return 1
        fi

        local stats_collide_direct stats_collide_relay
        stats_collide_direct=$(jq -r --argjson port "$stats_port" '
            .nodes[] | select(.direct_port == $port) | .name
        ' "$file")
        if [ -n "$stats_collide_direct" ]; then
            error "stats.public_port collides with direct_port on node(s): $stats_collide_direct"
            return 1
        fi

        stats_collide_relay=$(jq -r --argjson base "$base" --argjson port "$stats_port" '
            .nodes[] | select((.id + $base) == $port) | .name
        ' "$file")
        if [ -n "$stats_collide_relay" ]; then
            error "stats.public_port collides with relay port for node(s): $stats_collide_relay"
            return 1
        fi
    fi

    return 0
}

inv_relay_port_base() { jq -r '.relay_port_base // 8442' "$1"; }
inv_dns1()             { jq -r '.resolvers.dns1 // "1.1.1.1"' "$1"; }
inv_dns2()             { jq -r '.resolvers.dns2 // "8.8.8.8"' "$1"; }
inv_hold_valid()       { jq -r '.resolvers.hold_valid // "10s"' "$1"; }

inv_node_names() { jq -r '.nodes[].name' "$1"; }

inv_node_friendly_name() {
    local file="$1" name="$2"
    jq -r --arg n "$name" '(.nodes[] | select(.name == $n) | .friendly_name) // $n' "$file"
}

inv_node_exists() {
    local file="$1" name="$2"
    jq -e --arg n "$name" '.nodes[] | select(.name == $n)' "$file" >/dev/null 2>&1
}

inv_node_field() {
    local file="$1" name="$2" field="$3"
    jq -r --arg n "$name" --arg f "$field" '.nodes[] | select(.name == $n) | .[$f]' "$file"
}

# ssh_user/ssh_key are required per node (enforced by inv_validate) - no global fallback.
inv_node_ssh_user() { inv_node_field "$1" "$2" ssh_user; }
inv_node_ssh_key()  { inv_node_field "$1" "$2" ssh_key; }
inv_stats_node_port() { jq -r '.stats.node_port // 9091' "$1"; }
inv_stats_public_port() { jq -r '.stats.public_port // 9092' "$1"; }
inv_stats_web_port() { jq -r '.stats.web_port // 9093' "$1"; }
inv_stats_app_port() { jq -r '.stats.app_port // 9094' "$1"; }
inv_stats_master_node() { jq -r '.stats.master_node // ""' "$1"; }
inv_stats_postgres_port() { jq -r '.stats.postgres_port // 55432' "$1"; }
inv_stats_postgres_password() { jq -r '.stats.postgres_password // ""' "$1"; }
inv_stats_token() { jq -r '.stats.token // ""' "$1"; }
inv_stats_expose_haproxy() { jq -r '.stats.expose_via_haproxy // false' "$1"; }
inv_stats_rate_limit_period() { jq -r '.stats.rate_limit_period // "60s"' "$1"; }
inv_stats_rate_limit_requests() { jq -r '.stats.rate_limit_requests // 60' "$1"; }
inv_stats_allowed_sources() { jq -r '.stats.allowed_sources // [] | join(" ")' "$1"; }

# relay port used mesh-wide to reach $name = relay_port_base + $name's id.
inv_relay_port() {
    local file="$1" name="$2"
    local base id
    base=$(inv_relay_port_base "$file")
    id=$(inv_node_field "$file" "$name" id)
    echo $(( base + id ))
}

# Prints "name host direct_port relay_port" for every node EXCEPT $2, one per line.
inv_peers_of() {
    local file="$1" self="$2"
    local base
    base=$(inv_relay_port_base "$file")
    jq -r --arg self "$self" --argjson base "$base" '
        .nodes[]
        | select(.name != $self)
        | "\(.name) \(.host) \(.direct_port) \(.id + $base)"
    ' "$file"
}

# ---- xray / reality (shared across every node - see inventory.json "xray" block) ----

inv_xray_private_key() { jq -r '.xray.reality.private_key // ""' "$1"; }
inv_xray_public_key()  { jq -r '.xray.reality.public_key // ""' "$1"; }
inv_xray_short_id()    { jq -r '.xray.reality.short_id // "891f7782a08e5aae"' "$1"; }
inv_xray_sni()         { jq -r '.xray.reality.sni // "dl.google.com"' "$1"; }
inv_xray_dns1()        { jq -r '.xray.dns.dns1 // "172.29.0.10"' "$1"; }
inv_xray_dns2()        { jq -r '.xray.dns.dns2 // "94.140.14.14"' "$1"; }

# Raw JSON array of {uuid,email} objects.
inv_xray_users_json() { jq -c '.xray.users // []' "$1"; }

inv_xray_has_reality_keys() {
    local file="$1" priv pub
    priv=$(inv_xray_private_key "$file")
    pub=$(inv_xray_public_key "$file")
    [ -n "$priv" ] && [ -n "$pub" ]
}

# Persists generated Reality keys back into the inventory file in place
# (atomic write via temp file + mv) so every node stays in sync going forward.
inv_xray_set_reality_keys() {
    local file="$1" priv="$2" pub="$3"
    local tmp
    tmp="$(mktemp)"
    jq --arg priv "$priv" --arg pub "$pub" \
        '.xray.reality.private_key = $priv | .xray.reality.public_key = $pub' \
        "$file" > "$tmp" && mv "$tmp" "$file"
}

# Removes node $2 from the inventory in place (used by remove_node.sh).
inv_remove_node() {
    local file="$1" name="$2"
    local tmp
    tmp="$(mktemp)"
    jq --arg n "$name" '.nodes |= map(select(.name != $n))' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ---- subs / CDN (see inventory.json "subs" block) ----

inv_subs_domain()          { jq -r '.subs.domain // ""' "$1"; }
inv_subs_zone_domain()     { jq -r '.subs.zone_domain // ""' "$1"; }
inv_subs_caddy_host()      { jq -r '.subs.caddy_host // ""' "$1"; }
inv_subs_caddy_deploy_dir(){ jq -r '.subs.caddy_deploy_dir // "/opt/caddy-subs"' "$1"; }
inv_subs_ssh_user()        { jq -r '.subs.ssh_user // ""' "$1"; }
inv_subs_ssh_key()         { jq -r '.subs.ssh_key // ""' "$1"; }
inv_subs_secret()          { jq -r '.subs.sub_secret // ""' "$1"; }
inv_subs_origin_verify_secret() { jq -r '.subs.origin_verify_secret // ""' "$1"; }

# ---- images (see inventory.json "images" block) ----
# Single source of truth for the container image refs the xray stack pulls.
# Default to :latest; override per-inventory by setting images.xray / images.warp
# / images.adguard to a pinned tag or digest (e.g. "teddysun/xray:26.7.11" or
# "teddysun/xray@sha256:<digest>") - that is the recommended way to make a
# deploy reproducible. These are rendered into the per-node .env, so a change
# here reaches every node on the next deploy/deploy_nodes run.
inv_image_xray()    { jq -r '.images.xray // "teddysun/xray:latest"' "$1"; }
inv_image_warp()    { jq -r '.images.warp // "caomingjun/warp:latest"' "$1"; }
inv_image_adguard() { jq -r '.images.adguard // "adguard/adguardhome:latest"' "$1"; }
