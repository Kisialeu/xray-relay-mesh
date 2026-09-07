#!/usr/bin/env bash
# Explicit remote dependency bootstrap. Deployment commands never call this.

mesh_bootstrap_host() {
    local host="$1" enable_udp="${2:-false}"
    remote_bash "$host" "$enable_udp" <<'REMOTE'
set -euo pipefail
enable_udp=$1

if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y docker.io zstd cron
    if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
        sudo apt-get install -y docker-compose-v2
    else
        sudo apt-get install -y docker-compose-plugin
    fi
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y docker docker-compose-plugin zstd cronie
elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y docker docker-compose-plugin zstd cronie
else
    printf 'unsupported package manager; install Docker Engine, Compose, zstd, and cron manually\n' >&2
    exit 1
fi

sudo systemctl enable --now docker
if systemctl list-unit-files crond.service >/dev/null 2>&1; then
    sudo systemctl enable --now crond
fi

sudo modprobe tcp_bbr 2>/dev/null || true
sudo install -d -m 0755 /etc/modules-load.d /etc/sysctl.d
printf '%s\n' tcp_bbr | sudo tee /etc/modules-load.d/bbr.conf >/dev/null
printf '%s\n' net.ipv4.tcp_congestion_control=bbr | sudo tee /etc/sysctl.d/99-bbr.conf >/dev/null
sudo sysctl --system >/dev/null

if [ "$enable_udp" = true ]; then
    {
        printf '%s\n' net.core.rmem_max=16777216
        printf '%s\n' net.core.wmem_max=16777216
    } | sudo tee /etc/sysctl.d/99-hysteria-udp.conf >/dev/null
    sudo sysctl --system >/dev/null
fi

docker info >/dev/null
docker compose version >/dev/null
command -v zstd >/dev/null
command -v cron >/dev/null || command -v crond >/dev/null
REMOTE
}
