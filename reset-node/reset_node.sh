#!/usr/bin/env bash
# Hard-reset one inventory node so it can be redeployed from scratch.
# Only mesh-managed Compose stacks, resources, deployment directories, and
# system hooks are targeted. Unrelated Docker resources are left untouched.
#
# Usage: reset-node/reset_node.sh <node_name> [inventory.json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/inventory.sh"

usage() { echo "Usage: $0 <node_name> [inventory.json]" >&2; exit 1; }
[ $# -ge 1 ] || usage

NODE="$1"
INVENTORY="${2:-$MESH_DIR/inventory.json}"

mesh_check_local_deps
inv_validate "$INVENTORY" || exit 1
inv_node_exists "$INVENTORY" "$NODE" \
    || { error "node '$NODE' not found in inventory: $INVENTORY"; exit 1; }

mesh_resolve_ssh "$INVENTORY" "$NODE"
HOST="$(inv_node_field "$INVENTORY" "$NODE" host)"

XRAY_DIR="${XRAY_DEPLOY_DIR:-/opt/xray-node}"
RELAY_DIR="${RELAY_DEPLOY_DIR:-/opt/relay-node}"
STATS_DIR="${STATS_DEPLOY_DIR:-/opt/xray-stats}"
WEB_DIR="${WEB_DEPLOY_DIR:-/opt/xray-web}"
CADDY_DIR="${CADDY_DEPLOY_DIR:-$(inv_subs_caddy_deploy_dir "$INVENTORY")}"
PUBLIC_PORT="$(inv_stats_public_port "$INVENTORY")"
APP_PORT="$(inv_stats_app_port "$INVENTORY")"
ALLOWED_SOURCES="$(inv_stats_allowed_sources "$INVENTORY")"

for port in "$PUBLIC_PORT" "$APP_PORT"; do
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
        || { error "refusing unsafe reset port: $port"; exit 1; }
done
for source in $ALLOWED_SOURCES; do
    [[ "$source" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] \
        || { error "refusing unsafe stats firewall source: $source"; exit 1; }
done

for reset_dir in "$XRAY_DIR" "$RELAY_DIR" "$STATS_DIR" "$WEB_DIR" "$CADDY_DIR"; do
    [[ "$reset_dir" =~ ^/opt/[A-Za-z0-9._/-]+$ ]] \
        || { error "refusing unsafe reset path: $reset_dir"; exit 1; }
    case "$reset_dir" in
        /opt|/opt/|*..*) error "refusing unsafe reset path: $reset_dir"; exit 1 ;;
    esac
done

echo "Node:      $NODE ($HOST)"
echo "Inventory: $INVENTORY (will not be modified)"
echo "Compose stacks: Xray, relay, stats, web, Caddy"
echo "Directories to remove:"
printf '  - %s\n' "$XRAY_DIR" "$RELAY_DIR" "$STATS_DIR" "$WEB_DIR" "$CADDY_DIR"
echo ""
echo "This permanently removes the mesh deployment from the node."
echo "It also deletes the central stats database and TLS certificates if present."
echo "Unrelated Docker containers and resources are not targeted."
read -r -p "Type '$NODE' to confirm: " confirmation
[ "$confirmation" = "$NODE" ] || { echo "Aborted."; exit 0; }

info "$NODE ($HOST): stopping mesh containers and removing mesh resources"
ssh_run "$HOST" "
    set -u
    mesh_containers='xray warp adguard-home xray-relay xray-stats xray-stats-postgres xray-stats-web xray-stats-certbot xray-web-app xray-stats-web-app stats-web-app stats-web caddy-subs'
    mesh_images=\"\$(for container in \$mesh_containers; do sudo docker inspect -f '{{.Image}}' \"\$container\" 2>/dev/null || true; done | sort -u)\"

    for compose in \
        '$XRAY_DIR/docker-compose.yml' \
        '$RELAY_DIR/docker-compose.yml' \
        '$STATS_DIR/docker-compose.yml' \
        '$WEB_DIR/docker-compose.yml' \
        '$CADDY_DIR/compose.yml'; do
        if sudo test -f \"\$compose\"; then
            compose_dir=\$(dirname \"\$compose\")
            (cd \"\$compose_dir\" && sudo docker compose -f \"\$compose\" down --remove-orphans --volumes --rmi all) || true
        fi
    done

    for container in \$mesh_containers; do
        sudo docker rm -f \"\$container\" 2>/dev/null || true
    done
    for image in \$mesh_images; do
        sudo docker image rm \"\$image\" 2>/dev/null || true
    done

    for project in xray-node relay-node xray-stats xray-web caddy-subs; do
        for volume in \$(sudo docker volume ls -q --filter \"label=com.docker.compose.project=\$project\"); do
            sudo docker volume rm \"\$volume\" 2>/dev/null || true
        done
    done

    if command -v iptables >/dev/null 2>&1; then
        for port in '$PUBLIC_PORT' '$APP_PORT'; do
            while sudo iptables -C INPUT -p tcp --dport \"\$port\" -j ACCEPT 2>/dev/null; do
                sudo iptables -D INPUT -p tcp --dport \"\$port\" -j ACCEPT || break
            done
            for source in $ALLOWED_SOURCES; do
                while sudo iptables -C INPUT -s \"\$source\" -p tcp --dport \"\$port\" -j ACCEPT 2>/dev/null; do
                    sudo iptables -D INPUT -s \"\$source\" -p tcp --dport \"\$port\" -j ACCEPT || break
                done
            done
        done
        if command -v netfilter-persistent >/dev/null 2>&1; then
            sudo netfilter-persistent save >/dev/null 2>&1 || true
        elif [ -d /etc/iptables ]; then
            sudo sh -c 'iptables-save > /etc/iptables/rules.v4' || true
        fi
    fi

    sudo rm -f /usr/local/sbin/xray-stats-poller
    sudo rm -f /etc/logrotate.d/xray /etc/cron.d/xray-restart /var/log/xray-restart.log
    for auth in \$(getent passwd stats-poller 2>/dev/null | cut -d: -f6); do
        if [ -f \"\$auth/.ssh/authorized_keys\" ]; then
            sudo sed -i '/xray-stats-poller/d' \"\$auth/.ssh/authorized_keys\"
        fi
    done
    sudo rm -rf '$XRAY_DIR' '$RELAY_DIR' '$STATS_DIR' '$WEB_DIR' '$CADDY_DIR'
"

success "$NODE ($HOST): mesh deployment hard-reset"
echo "Inventory unchanged: $INVENTORY"
echo "The node can be deployed again with:"
echo "  ./mesh.sh deploy-node $NODE"
echo "  ./mesh.sh deploy-relay $NODE"
