#!/usr/bin/env bash
# Builds vless:// links and per-user subscription files from inventory.json.
# Reality crypto params (pbk/sni/sid) are identical on every node by design,
# so a relay link only differs from a direct link in host:port.
# Sourced by generate_subscriptions.sh - not meant to be run directly.

build_vless_link() {
    local uuid="$1" host="$2" port="$3" fragment="$4" pubkey="$5" sni="$6" short_id="$7" fp="$8"
    printf 'vless://%s@%s:%s?encryption=none&type=tcp&security=reality&pbk=%s&fp=%s&sni=%s&sid=%s&flow=xtls-rprx-vision#%s' \
        "$uuid" "$host" "$port" "$pubkey" "$fp" "$sni" "$short_id" "$(jq -rn --arg s "$fragment" '$s|@uri')"
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

    local direct_nodes relay_pairs
    direct_nodes=$(jq -r '.nodes[] | "\(.name)\t\(.host)\t\(.direct_port)\t\(.friendly_name // .name)"' "$file")
    relay_pairs=$(build_relay_pairs "$file")

    while IFS=$'\t' read -r uuid email; do
        [ -z "$uuid" ] && continue

        while IFS=$'\t' read -r name host port display_name; do
            [ -z "$name" ] && continue
            user_hidden_on_node "$file" "$name" "$email" && continue
            printf '%s\t%s\n' "$email" \
                "$(build_vless_link "$uuid" "$host" "$port" "${display_name} direct" "$pubkey" "$sni" "$short_id" "$fp")"
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

# Writes per-user subscription files into $sub_dir, in the same format the
# existing Caddy pipeline already serves (sub.b64, sub.url, sub.qr.png) and
# the old deploy.sh already produced. $all_links is "email<TAB>link" lines
# (from build_all_links). Safe to re-run - overwrites only, no leftover state.
write_subscription_files() {
    local sub_dir="$1" sub_secret="$2" sub_domain="$3" all_links="$4"
    local email links_raw links_b64 token user_dir tmp count

    mkdir -p "$sub_dir"

    while IFS= read -r email; do
        [ -z "$email" ] && continue
        links_raw=$(printf '%s\n' "$all_links" | awk -F'\t' -v e="$email" '$1==e {print $2}')
        token=$(printf '%s:%s' "$email" "$sub_secret" | sha256sum | awk '{print $1}' | cut -c1-40)
        user_dir="$sub_dir/$email"
        mkdir -p "$user_dir"

        links_b64=$(printf '%s' "$links_raw" | base64 -w 0)

        printf '%s\n' "$token" > "${user_dir}/sub.token"

        tmp="${user_dir}/sub.b64.tmp"
        printf '%s\n' "$links_b64" > "$tmp"
        mv -f "$tmp" "${user_dir}/sub.b64"

        tmp="${user_dir}/sub.links.tmp"
        printf '%s\n' "$links_raw" > "$tmp"
        mv -f "$tmp" "${user_dir}/sub.links"

        printf 'https://%s/%s\n' "$sub_domain" "$token" > "${user_dir}/sub.url"

        if command -v qrencode >/dev/null 2>&1; then
            qrencode -s 8 -m 2 -l H -o "${user_dir}/sub.qr.png" "https://${sub_domain}/${token}" 2>/dev/null \
                || warn "qrencode failed for $email"
        fi

        count=$(printf '%s\n' "$links_raw" | wc -l | tr -d ' ')
        success "subscription: $email -> https://${sub_domain}/${token} ($count links)"
    done < <(printf '%s\n' "$all_links" | cut -f1 | sort -u)
}
