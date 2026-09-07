#!/usr/bin/env bash
# Portable mkdir-based locks for local inventory mutation.

mesh_lock_acquire() {
    local lock_dir="$1" timeout="${2:-10}" waited=0
    [[ "$timeout" =~ ^[0-9]+$ ]] || { error "invalid lock timeout: $timeout"; return 1; }

    while ! mkdir "$lock_dir" 2>/dev/null; do
        if [ "$waited" -ge "$timeout" ]; then
            error "timed out waiting for lock: $lock_dir"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    printf '%s\n' "$$" > "$lock_dir/pid"
}

mesh_lock_release() {
    local lock_dir="$1"
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
}
