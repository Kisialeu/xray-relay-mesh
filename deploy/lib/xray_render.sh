#!/usr/bin/env bash
# Renders the per-node Xray stack files (.env, config.json, AdGuard Home
# config) from inventory.json. Reality keys and users are shared across
# every node; only HOSTNAME/VLESS_PORT vary per node.
# Sourced by other relay-mesh/deploy/*.sh scripts - not meant to be run directly.

render_xray_env() {
    local file="$1" node="$2"
    local port host priv pub short_id sni
    local xray_img warp_img adguard_img
    port=$(inv_node_field "$file" "$node" direct_port)
    host=$(inv_node_field "$file" "$node" host)
    priv=$(inv_xray_private_key "$file")
    pub=$(inv_xray_public_key "$file")
    short_id=$(inv_xray_short_id "$file")
    sni=$(inv_xray_sni "$file")
    # Container image refs - from the inventory "images" block (:latest by
    # default; pin to a tag/digest there for reproducible deploys).
    xray_img=$(inv_image_xray "$file")
    warp_img=$(inv_image_warp "$file")
    adguard_img=$(inv_image_adguard "$file")

    cat << EOF
VLESS_PORT=${port}
HOSTNAME=${host}
REALITY_PRIVATE_KEY=${priv}
REALITY_PUBLIC_KEY=${pub}
REALITY_SHORT_ID=${short_id}
REALITY_SNI=${sni}
XRAY_IMAGE=${xray_img}
WARP_IMAGE=${warp_img}
ADGUARD_IMAGE=${adguard_img}
EOF
}

# Builds config/config.json (variant E - same shape as the original deploy.sh)
# entirely with jq, driven by inventory fields instead of env vars/CLI args.
render_xray_config_json() {
    local file="$1" node="$2"
    local port priv sni short_id dns1 dns2 users_json dns1_cidr

    port=$(inv_node_field "$file" "$node" direct_port)
    priv=$(inv_xray_private_key "$file")
    sni=$(inv_xray_sni "$file")
    short_id=$(inv_xray_short_id "$file")
    dns1=$(inv_xray_dns1 "$file")
    dns2=$(inv_xray_dns2 "$file")
    users_json=$(inv_xray_users_json "$file")
    dns1_cidr="${dns1}/32"

    local clients_json
    clients_json=$(jq -c '[.[] | {id: .uuid, email: .email, flow: "xtls-rprx-vision", level: 0}]' <<< "$users_json")

    jq -n \
        --argjson port "$port" \
        --argjson clients "$clients_json" \
        --arg private_key "$priv" \
        --arg sni "$sni" \
        --arg short_id "$short_id" \
        --arg dns1 "$dns1" \
        --arg dns2 "$dns2" \
        --arg xray_dns1_cidr "$dns1_cidr" \
        '{
          "log": {
            "loglevel": "warning",
            "access": "/var/log/xray/access.log",
            "error": "/var/log/xray/error.log"
          },
          "api": {
            "tag": "api",
            "services": ["StatsService", "HandlerService"]
          },
          "dns": {
            "tag": "dns-out",
            "servers": [
              {"address": $dns1, "port": 53},
              {"address": $dns2, "port": 53}
            ],
            "queryStrategy": "UseIPv4",
            "disableFallback": true,
            "disableCache": false
          },
          "policy": {
            "levels": {
              "0": {
                "handshake": 4,
                "connIdle": 300,
                "uplinkOnly": 2,
                "downlinkOnly": 2,
                "bufferSize": 8176,
                "statsUserUplink": true,
                "statsUserDownlink": true,
                "statsUserOnline": true
              }
            },
            "system": {
              "statsInboundUplink": true,
              "statsInboundDownlink": true,
              "statsOutboundUplink": true,
              "statsOutboundDownlink": true
            }
          },
          "stats": {},
          "inbounds": [
            {
              "listen": "127.0.0.1",
              "port": 4431,
              "protocol": "dokodemo-door",
              "tag": "reality-dest",
              "settings": {
                "address": $sni,
                "port": 443,
                "network": "tcp"
              },
              "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": false
              }
            },
            {
              "port": $port,
              "protocol": "vless",
              "tag": "vless-in",
              "settings": {
                "clients": $clients,
                "decryption": "none"
              },
              "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                  "show": false,
                  "dest": "127.0.0.1:4431",
                  "serverNames": [$sni],
                  "privateKey": $private_key,
                  "shortIds": [$short_id, "a1b2c3d4e5f60718", "deadbeef12345678", "0102030405060708"],
                  "minClientVer": "0.0.0",
                  "maxTimeDiff": 60000,
                  "padding": true,
                  "spiderX": "/",
                  "limitFallbackUpload": {"capacity": 10000, "rate": 1000},
                  "limitFallbackDownload": {"capacity": 10000, "rate": 1000}
                },
                "sockopt": {
                  "tcpFastOpen": true,
                  "tcpKeepAliveIdle": 30,
                  "tcpKeepAliveInterval": 30,
                  "tcpUserTimeout": 10000,
                  "tcpcongestion": "bbr"
                }
              },
              "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
              }
            },
            {
              "listen": "127.0.0.1",
              "port": 10085,
              "protocol": "dokodemo-door",
              "settings": {"address": "127.0.0.1"},
              "tag": "api-in"
            }
          ],
          "outbounds": [
            {
              "protocol": "socks",
              "tag": "warp",
              "settings": {
                "servers": [{"address": "warp", "port": 1080}]
              },
              "streamSettings": {
                "sockopt": {
                  "tcpFastOpen": true,
                  "tcpKeepAliveIdle": 30,
                  "tcpKeepAliveInterval": 30,
                  "tcpUserTimeout": 10000,
                  "tcpcongestion": "bbr"
                }
              }
            },
            {
              "protocol": "freedom",
              "tag": "direct",
              "settings": {"domainStrategy": "UseIPv4"},
              "streamSettings": {
                "sockopt": {
                  "tcpFastOpen": true,
                  "tcpKeepAliveInterval": 30,
                  "tcpcongestion": "bbr",
                  "tcpUserTimeout": 10000,
                  "mark": 0
                }
              }
            },
            {
              "protocol": "blackhole",
              "tag": "block",
              "settings": {
                "response": {"type": "http"}
              }
            }
          ],
          "routing": {
            "domainStrategy": "IPIfNonMatch",
            "domainMatcher": "mph",
            "rules": [
              {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"},
              {"type": "field", "inboundTag": ["dns-out"], "ip": [$xray_dns1_cidr], "outboundTag": "direct"},
              {"type": "field", "inboundTag": ["dns-out"], "outboundTag": "warp"},
              {"type": "field", "inboundTag": ["reality-dest"], "domain": [$sni], "outboundTag": "direct"},
              {"type": "field", "inboundTag": ["reality-dest"], "outboundTag": "block"},
              {"type": "field", "ip": ["2000::/3", "fc00::/7", "fe80::/10", "::1/128"], "outboundTag": "block"},
              {"type": "field", "ip": [$xray_dns1_cidr], "outboundTag": "direct"},
              {"type": "field", "ip": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16"], "outboundTag": "block"},
              {"type": "field", "ip": ["geoip:ru"], "outboundTag": "warp"},
              {"type": "field", "domain": ["geosite:category-gov-ru"], "outboundTag": "warp"},
              {"type": "field", "inboundTag": ["vless-in"], "outboundTag": "direct"}
            ]
          }
        }'
}

render_adguard_yaml() {
    local file="$1"
    local sni
    sni=$(inv_xray_sni "$file")

    cat << EOF
http:
  pprof:
    port: 6060
    enabled: false
  address: 0.0.0.0:3000
  session_ttl: 720h
auth_attempts: 5
block_auth_min: 15
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  upstream_dns:
    - https://dns.adguard-dns.com/dns-query
    - https://dns.cloudflare.com/dns-query
  upstream_dns_file: ""
  bootstrap_dns:
    - 94.140.14.14
    - 94.140.15.15
  fallback_dns: []
  all_servers: false
  fastest_addr: true
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  refuse_any: true
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  filtering_enabled: true
  filters_update_interval: 24
  parental_enabled: false
  safe_browsing_enabled: false
  safe_browsing_cache_size: 1048576
  safe_search:
    enabled: false
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_4.txt
    name: MalwareDomainList.com Hosts List
    id: 4
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt
    name: AdGuard DNS Popup Hosts filter
    id: 59
  - enabled: true
    url: https://big.oisd.nl/domainswild
    name: OISD Big (wildcard)
    id: 102
  - enabled: true
    url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/pro.txt
    name: HaGeZi Multi PRO
    id: 103
  - enabled: true
    url: https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext
    name: Peter Lowe's Ad and tracking server list
    id: 104
  - enabled: true
    url: https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
    name: StevenBlack Unified hosts
    id: 105
user_rules:
  - "@@||${sni}^"
  - "@@||www.googletagmanager.com^"
  - "@@||telemetry.individual.githubcopilot.com^"
  - "||ad.youtube.com^"
  - "||doubleclick.net^"
  - "||googlesyndication.com^"
  - "||googleadservices.com^"
  - "||pagead2.googlesyndication.com^"
  - "||ads.youtube.com^"
  - "||youtubei.googleapis.com/youtubei/v1/log_event^"
  - "||taboola.com^"
  - "||outbrain.com^"
  - "||revcontent.com^"
  - "||mgid.com^"
  - "||contentad.net^"
  - "||zergnet.com^"
log:
  compress: false
  localtime: false
  max_backups: 0
  max_size: 100
  max_age: 3
  file: ""
  verbose: false
schema_version: 29
EOF
}
