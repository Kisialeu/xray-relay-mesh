#!/usr/bin/env bash
# Builds vless:// and hysteria2:// links and per-user subscription files from
# inventory.json. Reality crypto params (pbk/sni/sid) are identical on every
# node by design, so a relay link only differs from a direct link in
# host:port. Hysteria2 links are direct-connect only (no relay - see
# lib/hysteria_render.sh) and only emitted for nodes with "hysteria" in
# their "protocols" array (per-node opt-in, see inv_node_has_hysteria).
# Sourced by generate_subscriptions.sh - not meant to be run directly.

# A bare IPv6 literal ("2001:db8::1") is ambiguous in a URI's host:port
# position (RFC 3986) - a parser can't tell the address from the port
# without brackets. Domains and IPv4 literals never contain ":", so this is
# a safe, unambiguous test - never treats a domain/IPv4 host as IPv6.
_uri_host() {
    case "$1" in
        *:*) printf '[%s]' "$1" ;;
        *)   printf '%s' "$1" ;;
    esac
}

build_vless_link() {
    local uuid="$1" host="$2" port="$3" fragment="$4" pubkey="$5" sni="$6" short_id="$7" fp="$8"
    printf 'vless://%s@%s:%s?encryption=none&type=tcp&security=reality&pbk=%s&fp=%s&sni=%s&sid=%s&flow=xtls-rprx-vision#%s' \
        "$uuid" "$(_uri_host "$host")" "$port" "$pubkey" "$fp" "$sni" "$short_id" "$(jq -rn --arg s "$fragment" '$s|@uri')"
}

# password reuses the user's existing UUID (auth model shared with VLESS - one
# identity per user, one place to revoke). sni must be the node's tls_domain,
# NOT its host/IP - Hysteria2 needs a real ACME cert (unlike Reality, which
# borrows a foreign site's handshake), and the connect address (host) can
# safely stay an IP because SNI/cert validation is independent of it.
build_hysteria2_link() {
    local email="$1" uuid="$2" host="$3" port="$4" sni="$5" fragment="$6" obfs_password="$7"
    local obfs_qs=""
    [ -n "$obfs_password" ] && obfs_qs="&obfs=salamander&obfs-password=$(jq -rn --arg s "$obfs_password" '$s|@uri')"
    printf 'hysteria2://%s:%s@%s:%s/?sni=%s%s#%s' \
        "$(jq -rn --arg s "$email" '$s|@uri')" \
        "$(jq -rn --arg s "$uuid" '$s|@uri')" \
        "$(_uri_host "$host")" "$port" \
        "$(jq -rn --arg s "$sni" '$s|@uri')" \
        "$obfs_qs" \
        "$(jq -rn --arg s "$fragment" '$s|@uri')"
}

build_singbox_vless_outbound() {
    local tag="$1" uuid="$2" host="$3" port="$4" pubkey="$5" sni="$6" short_id="$7" fp="$8"
    jq -cn --arg tag "$tag" --arg uuid "$uuid" --arg host "$host" \
        --arg pubkey "$pubkey" --arg sni "$sni" --arg short_id "$short_id" --arg fp "$fp" \
        --argjson port "$port" '{
        type: "vless", tag: $tag, server: $host, server_port: $port,
        uuid: $uuid, flow: "xtls-rprx-vision", packet_encoding: "xudp",
        tls: {
            enabled: true, server_name: $sni,
            utls: {enabled: true, fingerprint: $fp},
            reality: {enabled: true, public_key: $pubkey, short_id: $short_id}
        }
    }'
}

build_singbox_hysteria2_outbound() {
    local tag="$1" email="$2" uuid="$3" host="$4" port="$5" sni="$6" obfs_password="$7"
    jq -cn --arg tag "$tag" --arg email "$email" --arg uuid "$uuid" --arg host "$host" \
        --arg sni "$sni" --arg obfs_password "$obfs_password" --argjson port "$port" \
        '{type: "hysteria2", tag: $tag, server: $host, server_port: $port,
          password: ($email + ":" + $uuid), tls: {enabled: true, server_name: $sni}}
         | if $obfs_password == "" then . else .obfs = {type: "salamander", password: $obfs_password} end'
}

build_singbox_config() {
    local dns1="$1" outbounds_json="$2"
    jq -cn --arg dns1 "$dns1" --argjson real_outbounds "$outbounds_json" '
        ($real_outbounds | map(.tag)) as $tags
        | if ($tags | length) == 0 then error("sing-box profile has no outbounds") else
          {
            dns: {
              servers: [
                {tag: "adguard", address: $dns1, detour: "proxy"},
                {tag: "local", type: "local"}
              ],
              rules: [{outbound: ["any"], action: "route", server: "adguard"}]
            },
            outbounds: ($real_outbounds + [{type: "selector", tag: "proxy", outbounds: $tags, default: $tags[0]}]),
            route: {final: "proxy"}
          }
          end
    '
}

build_incy_routing_profile() {
    local dns1="$1"
    jq -cn --arg dns1 "$dns1" --arg updated "$(date +%s)" '{
        Name: "Xray Relay Mesh",
        GlobalProxy: "true",
        LastUpdated: $updated,
        RemoteDNSType: "DoU",
        RemoteDNSIP: $dns1,
        DirectSites: [],
        DirectIp: [],
        ProxySites: [],
        ProxyIp: [],
        BlockSites: ["geosite:category-ads-all"],
        BlockIp: [],
        DomainStrategy: "IPIfNonMatch"
    }'
}

user_hidden_on_node() {
    local file="$1" node_name="$2" email="$3"
    jq -r --arg email "$email" '
        .xray.users[]
        | select(.email == $email)
        | .hidden_nodes[]?
    ' "$file" | grep -Fxq "$node_name"
}

# Prints "entry_display<TAB>entry_host<TAB>peer_display<TAB>relay_port" for every
# node with is_relay_entry:true, crossed with every one of its peers. Only these
# nodes' relay ports get published to subscriptions - curated, so link count
# stays O(entries x N) instead of O(N^2) as the mesh grows.
build_relay_pairs() {
    local file="$1" base
    base=$(inv_relay_port_base "$file")
    jq -r --argjson base "$base" '
        [.nodes[] | select(.is_relay_entry == true)] as $entries
        | .nodes as $all
        | $entries[] as $e
        | $all[] | select(.name != $e.name)
        | "\($e.friendly_name // $e.name)\t\($e.host)\t\(.friendly_name // .name)\t\(.id + $base)"
    ' "$file"
}

# Prints "email<TAB>link" for every user x every node (direct), and every
# user x every relay-entry/peer pair (relay). One line per link.
build_all_links() {
    local file="$1"
    local pubkey sni short_id fp
    pubkey=$(inv_xray_public_key "$file")
    sni=$(inv_xray_sni "$file")
    short_id=$(inv_xray_short_id "$file")
    fp="${LINK_FP:-firefox}"

    if [ -z "$pubkey" ]; then
        error "xray.reality.public_key is empty in inventory - run deploy/deploy_nodes.sh first"
        return 1
    fi

    local hysteria_node_names hysteria_obfs_password
    hysteria_node_names=$(inv_hysteria_node_names "$file")
    hysteria_obfs_password=$(inv_hysteria_obfs_password "$file")

    local direct_nodes relay_pairs
    direct_nodes=$(jq -r '.nodes[] | "\(.name)\t\(.host)\t\(.direct_port)\t\(.friendly_name // .name)\t\(.tls_domain // "")"' "$file")
    relay_pairs=$(build_relay_pairs "$file")

    while IFS=$'\t' read -r uuid email; do
        [ -z "$uuid" ] && continue

        while IFS=$'\t' read -r name host port display_name tls_domain; do
            [ -z "$name" ] && continue
            user_hidden_on_node "$file" "$name" "$email" && continue
            printf '%s\t%s\n' "$email" \
                "$(build_vless_link "$uuid" "$host" "$port" "${display_name} direct" "$pubkey" "$sni" "$short_id" "$fp")"

            if [ -n "$tls_domain" ] && grep -Fxq "$name" <<< "$hysteria_node_names"; then
                printf '%s\t%s\n' "$email" \
                    "$(build_hysteria2_link "$email" "$uuid" "$host" "$port" "$tls_domain" "${display_name} (UDP)" "$hysteria_obfs_password")"
            fi
        done <<< "$direct_nodes"

        while IFS=$'\t' read -r entry_name entry_host peer_name relay_port; do
            [ -z "$entry_name" ] && continue
            user_hidden_on_node "$file" "$entry_name" "$email" && continue
            user_hidden_on_node "$file" "$peer_name" "$email" && continue
            printf '%s\t%s\n' "$email" \
                "$(build_vless_link "$uuid" "$entry_host" "$relay_port" "${peer_name} via ${entry_name}" "$pubkey" "$sni" "$short_id" "$fp")"
        done <<< "$relay_pairs"
    done < <(jq -r '.xray.users[] | "\(.uuid)\t\(.email)"' "$file")
}

build_all_singbox_outbounds() {
    local file="$1"
    local pubkey sni short_id fp
    pubkey=$(inv_xray_public_key "$file")
    sni=$(inv_xray_sni "$file")
    short_id=$(inv_xray_short_id "$file")
    fp="${LINK_FP:-firefox}"
    [ -n "$pubkey" ] || { error "xray.reality.public_key is empty in inventory"; return 1; }

    local hysteria_node_names hysteria_obfs_password
    hysteria_node_names=$(inv_hysteria_node_names "$file")
    hysteria_obfs_password=$(inv_hysteria_obfs_password "$file")
    local direct_nodes relay_pairs
    direct_nodes=$(jq -r '.nodes[] | [.name, .host, .direct_port, (.friendly_name // .name), (.tls_domain // "")] | @tsv' "$file")
    relay_pairs=$(build_relay_pairs "$file")

    while IFS=$'\t' read -r uuid email; do
        [ -z "$uuid" ] && continue
        while IFS=$'\t' read -r name host port display_name tls_domain; do
            [ -z "$name" ] && continue
            user_hidden_on_node "$file" "$name" "$email" && continue
            printf '%s\t%s\n' "$email" "$(build_singbox_vless_outbound "vless-${name}" "$uuid" "$host" "$port" "$pubkey" "$sni" "$short_id" "$fp")"
            if [ -n "$tls_domain" ] && grep -Fxq "$name" <<< "$hysteria_node_names"; then
                printf '%s\t%s\n' "$email" "$(build_singbox_hysteria2_outbound "hysteria-${name}" "$email" "$uuid" "$host" "$port" "$tls_domain" "$hysteria_obfs_password")"
            fi
        done <<< "$direct_nodes"
        while IFS=$'\t' read -r entry_name entry_host peer_name relay_port; do
            [ -z "$entry_name" ] && continue
            user_hidden_on_node "$file" "$entry_name" "$email" && continue
            user_hidden_on_node "$file" "$peer_name" "$email" && continue
            printf '%s\t%s\n' "$email" "$(build_singbox_vless_outbound "vless-${peer_name}-via-${entry_name}" "$uuid" "$entry_host" "$relay_port" "$pubkey" "$sni" "$short_id" "$fp")"
        done <<< "$relay_pairs"
    done < <(jq -r '.xray.users[] | "\(.uuid)\t\(.email)"' "$file")
}

# Writes per-user subscription files into $sub_dir, in the same format the
# existing Caddy pipeline already serves (sub.b64, sub.url, sub.qr.png) and
# the old deploy.sh already produced. $all_links is "email<TAB>link" lines
# (from build_all_links). Safe to re-run - overwrites only, no leftover state.
write_subscription_files() {
    local sub_dir="$1" sub_secret="$2" sub_domain="$3" all_links="$4" all_singbox_outbounds="$5" dns1="$6"
    local email links_raw links_b64 singbox_json incy_json token user_dir tmp count

    mkdir -p "$sub_dir"

    while IFS= read -r email; do
        [ -z "$email" ] && continue
        links_raw=$(printf '%s\n' "$all_links" | awk -F'\t' -v e="$email" '$1==e {print $2}')
        singbox_json=$(printf '%s\n' "$all_singbox_outbounds" | awk -F'\t' -v e="$email" '$1==e {print $2}' | jq -s '.')
        incy_json=$(build_incy_routing_profile "$dns1")
        token=$(printf '%s:%s' "$email" "$sub_secret" | sha256sum | awk '{print $1}' | cut -c1-40)
        user_dir="$sub_dir/$email"
        mkdir -p "$user_dir"

        links_b64=$(printf '%s' "$links_raw" | mesh_base64_noline)

        printf '%s\n' "$token" > "${user_dir}/sub.token"

        tmp="${user_dir}/sub.b64.tmp"
        printf '%s\n' "$links_b64" > "$tmp"
        mv -f "$tmp" "${user_dir}/sub.b64"

        tmp="${user_dir}/sub.links.tmp"
        printf '%s\n' "$links_raw" > "$tmp"
        mv -f "$tmp" "${user_dir}/sub.links"

        printf 'https://%s/%s\n' "$sub_domain" "$token" > "${user_dir}/sub.url"

        tmp="${user_dir}/sub.singbox.json.tmp"
        build_singbox_config "$dns1" "$singbox_json" > "$tmp"
        mv -f "$tmp" "${user_dir}/sub.singbox.json"

        tmp="${user_dir}/sub.incy.json.tmp"
        printf '%s\n' "$incy_json" > "$tmp"
        mv -f "$tmp" "${user_dir}/sub.incy.json"

        if command -v qrencode >/dev/null 2>&1; then
            qrencode -s 8 -m 2 -l H -o "${user_dir}/sub.qr.png" "https://${sub_domain}/${token}" 2>/dev/null \
                || warn "qrencode failed for $email"
        fi

        count=$(printf '%s\n' "$links_raw" | wc -l | tr -d ' ')
        success "subscription generated: $email ($count links)"
    done < <(printf '%s\n' "$all_links" | cut -f1 | sort -u)
}
