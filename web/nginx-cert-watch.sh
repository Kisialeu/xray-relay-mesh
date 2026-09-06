#!/bin/sh
set -eu

(
    previous=""
    while sleep 60; do
        current="$(find -L /etc/letsencrypt/live -maxdepth 2 -type f \
            \( -name 'fullchain.pem' -o -name 'privkey.pem' \) \
            -exec stat -c '%n:%i:%Y:%s' {} \; 2>/dev/null | sort | sha256sum)"
        if [ -n "$current" ] && [ -n "$previous" ] && [ "$current" != "$previous" ]; then
            nginx -s reload || true
        fi
        previous="$current"
    done
) &
