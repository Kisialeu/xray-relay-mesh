#!/usr/bin/env bash
# jq-based accessors over an inventory.json file (see relay-mesh/inventory.json).
# Sourced by other relay-mesh/*.sh scripts - not meant to be run directly.

INVENTORY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lock.sh
source "$INVENTORY_LIB_DIR/lock.sh"

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

    jq -e '
        ((.environment // "development") | IN("development", "staging", "production")) and
        all(.nodes[];
            (.id | type == "number" and floor == . and . >= 0) and
            (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
            (.host | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$")) and
            (.direct_port | type == "number" and floor == . and . >= 1 and . <= 65535) and
            (.ssh_user | type == "string" and test("^[A-Za-z_][A-Za-z0-9._-]*$")) and
            (.ssh_key | type == "string" and length > 0 and (test("[\\x00-\\x1F]") | not))
        ) and
        all((.images // {}) | to_entries[] | select(.key | startswith("_") | not);
            (.value | type == "string" and test("^[A-Za-z0-9._/@:-]+$") and length > 0)
        ) and
        all(.xray.users[]?;
            (.uuid | type == "string" and test("^[0-9a-fA-F-]{36}$")) and
            (.email | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._@+-]*$") and (contains("..") | not)) and
            ((.hidden_nodes // []) as $hidden |
                if ($hidden | type) == "array" then
                    all($hidden[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
                elif ($hidden | type) == "object" then
                    all($hidden | to_entries[];
                        (.key | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
                        (((.value | type) == "string" and (.value | IN("all", "xray", "hysteria"))) or
                         ((.value | type) == "array" and (.value | length) > 0 and
                          all(.value[]; type == "string" and IN("xray", "hysteria"))))
                    )
                else false end)
        ) and
        ((.xray.reality.private_key // "") | test("^[A-Za-z0-9_-]*$")) and
        ((.xray.reality.public_key // "") | test("^[A-Za-z0-9_-]*$")) and
        ((.xray.reality.short_id // "891f7782a08e5aae") | test("^[0-9a-fA-F]{1,16}$")) and
        ((.xray.reality.sni // "dl.google.com") | test("^[A-Za-z0-9][A-Za-z0-9.-]*$")) and
        ((.stats.token // "") | test("^[A-Za-z0-9._~:-]*$")) and
        ((.stats.postgres_password // "") | test("^[A-Za-z0-9._~:-]*$")) and
        ((.subs.sub_secret // "") | test("^[A-Za-z0-9._~:-]*$")) and
        ((.subs.origin_verify_secret // "") | test("^[A-Za-z0-9._~:-]*$")) and
        ((.subs.domain // "") | test("^[A-Za-z0-9][A-Za-z0-9.-]*$")) and
        ((.subs.zone_domain // "") | test("^[A-Za-z0-9][A-Za-z0-9.-]*$")) and
        ((.subs.caddy_host // "") | test("^[A-Za-z0-9][A-Za-z0-9._:-]*$")) and
        ((.subs.ssh_user // "root") | test("^[A-Za-z_][A-Za-z0-9._-]*$")) and
        ((.subs.ssh_key // "~/.ssh/my_custom_key") | type == "string" and length > 0 and (test("[\\x00-\\x1F]") | not)) and
        ((.subs.profile_title // "Xray Relay Mesh") | type == "string" and length > 0 and length <= 25 and test("^[^\\r\\n]*$")) and
        ((.subs.profile_description // "") | type == "string" and length <= 240 and test("^[^\\r\\n]*$")) and
        ((.subs.support_url // "") | type == "string" and length <= 512 and (length == 0 or test("^https://[^[:space:]]+$"))) and
        ((.subs.support_email // "") | type == "string" and length <= 254 and (length == 0 or test("^[A-Za-z0-9.!#$%&*+/=?^_{}|~-]+@[A-Za-z0-9.-]+$"))) and
        ((.subs.profile_update_interval // 24) | type == "number" and floor == . and . >= 1 and . <= 720) and
        ((.subs.app_proxy.enable // false) | type == "boolean") and
        ((.subs.app_proxy.mode // "") | type == "string" and (IN("", "bypass", "proxy"))) and
        ((.subs.app_proxy.packages // "") | type == "string" and length <= 2048 and test("^[A-Za-z0-9._, -]*$")) and
        ((.stats.ssh_user // "stats-poller") | test("^[A-Za-z_][A-Za-z0-9._-]*$")) and
        ((.subs.caddy_deploy_dir // "/opt/caddy-subs") |
            test("^/opt/[A-Za-z0-9._/-]+$") and
            (contains("..") | not) and
            (contains("//") | not)) and
        ((.subs.content_deploy_dir // ((.subs.caddy_deploy_dir // "/opt/caddy-subs") + "-content")) |
            test("^/opt/[A-Za-z0-9._/-]+$") and
            (contains("..") | not) and
            (contains("//") | not))
    ' "$file" >/dev/null 2>&1 || {
        error "inventory contains invalid environment, node identity, port, SSH value, or deploy path"
        return 1
    }

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

    if [ "$(jq -r '.environment // "development"' "$file")" = "production" ]; then
        local unpinned_images
        unpinned_images=$(jq -r '
            (.images // {})
            | to_entries[]
            | select(.key | startswith("_") | not)
            | select(
                (.value | type != "string") or
                (.value | test(":latest$")) or
                ((.value | test("(@sha256:[0-9a-fA-F]{64}|:[A-Za-z0-9_][A-Za-z0-9_.-]*)$")) | not)
            )
            | .key
        ' "$file")
        if [ -n "$unpinned_images" ]; then
            error "production inventory contains unpinned image(s): $unpinned_images"
            return 1
        fi
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

    local bad_protocols
    bad_protocols=$(jq -r '
        .nodes[]
        | select(.protocols != null)
        | select((.protocols | index("xray")) == null or ((.protocols - ["xray", "hysteria"]) | length) > 0)
        | .name
    ' "$file")
    if [ -n "$bad_protocols" ]; then
        error "node(s) protocols must include \"xray\" and contain only xray/hysteria: $bad_protocols"
        return 1
    fi

    local hysteria_nodes
    hysteria_nodes=$(jq -r '.nodes[] | select((.protocols // ["xray"]) | index("hysteria")) | .name' "$file")
    if [ -n "$hysteria_nodes" ]; then
        local hysteria_email missing_tls_domain shared_secret_count
        hysteria_email=$(inv_hysteria_acme_email "$file")
        if [ -z "$hysteria_email" ]; then
            error "hysteria.acme_email is required when any node has \"hysteria\" in its protocols: $hysteria_nodes"
            return 1
        fi

        missing_tls_domain=$(jq -r '
            .nodes[]
            | select((.protocols // ["xray"]) | index("hysteria"))
            | select((.tls_domain // "") == "")
            | .name
        ' "$file")
        if [ -n "$missing_tls_domain" ]; then
            error "node(s) with \"hysteria\" in protocols require tls_domain (ACME cannot issue for a bare IP): $missing_tls_domain"
            return 1
        fi

        shared_secret_count=$(jq -r '
            [.nodes[]
             | select((.protocols // ["xray"]) | index("hysteria"))
             | (.hysteria_stats_secret // "")
             | select(length > 0)]
            | unique
            | length
        ' "$file")
        if [ "$shared_secret_count" -gt 1 ]; then
            error "hysteria-enabled nodes must use the same hysteria_stats_secret"
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

inv_stats_set_master() {
    local file="$1" name="$2"
    inv_atomic_update "$file" --arg master "$name" '.stats.master_node = $master'
}

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

inv_validate_xray_deploy_secrets() {
    local file="$1" missing_hysteria_secret
    if ! inv_xray_has_reality_keys "$file"; then
        error "xray deployment requires existing Reality private_key and public_key values"
        return 1
    fi

    missing_hysteria_secret=$(jq -r '
        .nodes[]
        | select((.protocols // ["xray"]) | index("hysteria"))
        | select((.hysteria_stats_secret // "") == "")
        | .name
    ' "$file")
    if [ -n "$missing_hysteria_secret" ]; then
        error "hysteria-enabled node(s) missing shared hysteria_stats_secret: $missing_hysteria_secret"
        return 1
    fi

    return 0
}

inv_atomic_update() {
    local file="$1"
    shift
    local lock_dir="${file}.lock" backup="${file}.backup" tmp rc=0

    mesh_lock_acquire "$lock_dir" "${INVENTORY_LOCK_TIMEOUT:-10}" || return 1
    tmp="$(mktemp "${file}.tmp.XXXXXX")" || {
        mesh_lock_release "$lock_dir"
        return 1
    }

    cp -p "$file" "$backup" || rc=1
    if [ "$rc" -eq 0 ]; then
        jq "$@" "$file" > "$tmp" || rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        inv_validate "$tmp" || rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        local source_mode
        source_mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")
        chmod "$source_mode" "$tmp"
        mv "$tmp" "$file" || rc=1
    fi
    if [ "$rc" -eq 0 ] && ! inv_validate "$file"; then
        cp -p "$backup" "$file"
        rc=1
    fi

    rm -f "$tmp"
    mesh_lock_release "$lock_dir"
    return "$rc"
}

# Removes node $2 from the inventory in place (used by remove_node.sh).
inv_remove_node() {
    local file="$1" name="$2"
    inv_atomic_update "$file" --arg n "$name" '.nodes |= map(select(.name != $n))'
}

# ---- subs / CDN (see inventory.json "subs" block) ----

inv_subs_domain()          { jq -r '.subs.domain // ""' "$1"; }
inv_subs_zone_domain()     { jq -r '.subs.zone_domain // ""' "$1"; }
inv_subs_caddy_host()      { jq -r '.subs.caddy_host // ""' "$1"; }
inv_subs_caddy_deploy_dir(){ jq -r '.subs.caddy_deploy_dir // "/opt/caddy-subs"' "$1"; }
inv_subs_content_deploy_dir() {
    jq -r '.subs.content_deploy_dir // ((.subs.caddy_deploy_dir // "/opt/caddy-subs") + "-content")' "$1"
}
inv_subs_ssh_user()        { jq -r '.subs.ssh_user // ""' "$1"; }
inv_subs_ssh_key()         { jq -r '.subs.ssh_key // ""' "$1"; }
inv_subs_secret()          { jq -r '.subs.sub_secret // ""' "$1"; }
inv_subs_origin_verify_secret() { jq -r '.subs.origin_verify_secret // ""' "$1"; }
inv_subs_profile_title()     { jq -r '.subs.profile_title // "Xray Relay Mesh"' "$1"; }
inv_subs_profile_description(){ jq -r '.subs.profile_description // ""' "$1"; }
inv_subs_support_url()       { jq -r '.subs.support_url // ""' "$1"; }
inv_subs_support_email()     { jq -r '.subs.support_email // ""' "$1"; }
inv_subs_profile_update_interval() { jq -r '.subs.profile_update_interval // 24' "$1"; }
inv_subs_app_proxy_enable() { jq -r 'if .subs.app_proxy.enable == true then "true" else "false" end' "$1"; }
inv_subs_app_proxy_mode() { jq -r '.subs.app_proxy.mode // "proxy"' "$1"; }
inv_subs_app_proxy_packages() { jq -r '.subs.app_proxy.packages // ""' "$1"; }

# ---- images (see inventory.json "images" block) ----
# Single source of truth for the container image refs the xray stack pulls.
# Default to :latest; override per-inventory by setting images.xray / images.warp
# / images.adguard to a pinned tag or digest (e.g. "teddysun/xray:26.7.11" or
# "teddysun/xray@sha256:<digest>") - that is the recommended way to make a
# deploy reproducible. These are rendered into the per-node .env, so a change
# here reaches every node on the next Xray deployment.
inv_image_xray()    { jq -r '.images.xray // "teddysun/xray:latest"' "$1"; }
inv_image_warp()    { jq -r '.images.warp // "caomingjun/warp:latest"' "$1"; }
inv_image_adguard() { jq -r '.images.adguard // "adguard/adguardhome:latest"' "$1"; }
inv_image_hysteria() { jq -r '.images.hysteria // "tobyxdd/hysteria:latest"' "$1"; }

# ---- hysteria2 (see inventory.json "hysteria" block; per-node "protocols"/"tls_domain") ----
# Hysteria2 (github.com/apernet/hysteria, image tobyxdd/hysteria) is a
# separate UDP/QUIC server, not an Xray protocol - it runs as its own
# container, direct-connect only (no HAProxy relay - relay/lib/render.sh is
# TCP passthrough only by design). Every node always runs Xray (the relay
# mesh backbone); a node additionally runs Hysteria2 only if "hysteria" is
# in its "protocols" array (default: ["xray"] only - opt-in per node, NOT
# a single mesh-wide switch, since each node needs its own ACME cert/domain).
# It needs a real ACME cert, and Let's Encrypt cannot issue one for a bare
# IP, so each opted-in node needs its own "tls_domain" pointed at that
# node's host - separate from "host"/direct_port, which stay the actual
# connect address in links.
inv_hysteria_acme_email()     { jq -r '.hysteria.acme_email // ""' "$1"; }
inv_hysteria_masquerade_url() { jq -r '.hysteria.masquerade_url // ""' "$1"; }
inv_hysteria_up_mbps()        { jq -r '.hysteria.up_mbps // 200' "$1"; }
inv_hysteria_down_mbps()      { jq -r '.hysteria.down_mbps // 200' "$1"; }
# Optional Salamander obfuscation (shared across every hysteria-enabled node,
# same as acme_email/masquerade_url) - disguises the QUIC handshake so it
# doesn't fingerprint as QUIC to DPI-based traffic shaping. Off (no obfs
# block rendered, no obfs params in links) when left empty.
inv_hysteria_obfs_password()  { jq -r '.hysteria.obfs_password // ""' "$1"; }
# Fixed container-internal port for Hysteria2's own built-in trafficStats API
# (see https://v2.hysteria.network/docs/advanced/Traffic-Stats-API/) - never
# published to the host, same treatment as Xray's own gRPC API port 10085.
inv_hysteria_stats_port()     { jq -r '.hysteria.stats_port // 9999' "$1"; }

inv_node_tls_domain() { inv_node_field "$1" "$2" tls_domain; }

# Every Hysteria-enabled node must use the same trafficStats secret. Validation
# rejects divergent values without logging them. Deployment never generates or
# persists secrets.
inv_node_hysteria_stats_secret() { inv_node_field "$1" "$2" hysteria_stats_secret; }

inv_shared_hysteria_stats_secret() {
    jq -r '
        first(.nodes[]
              | select((.protocols // ["xray"]) | index("hysteria"))
              | (.hysteria_stats_secret // "")
              | select(length > 0)) // ""
    ' "$1"
}

# Generic per-node protocol membership check ("true"/"false" string, same
# convention as inv_stats_expose_haproxy etc.) - reusable for any protocol
# added to nodes[].protocols later, not just xray/hysteria.
inv_node_has_protocol() {
    local file="$1" name="$2" proto="$3"
    jq -r --arg n "$name" --arg p "$proto" '
        (.nodes[] | select(.name == $n) | (.protocols // ["xray"]) | any(. == $p))
    ' "$file"
}

# Names of every node with $2 in its protocols, one per line.
inv_protocol_node_names() {
    local file="$1" proto="$2"
    jq -r --arg p "$proto" '.nodes[] | select((.protocols // ["xray"]) | index($p)) | .name' "$file"
}

inv_node_has_hysteria()  { inv_node_has_protocol "$1" "$2" hysteria; }
inv_hysteria_node_names() { inv_protocol_node_names "$1" hysteria; }
