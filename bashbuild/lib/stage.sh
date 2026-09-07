#!/usr/bin/env bash
# Deterministic local staging manifests.

MESH_STAGE_DIRS=()

stage_create() {
    local result_var="$1" component="$2" created_dir
    [[ "$component" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || { error "invalid stage component: $component"; return 1; }
    created_dir="$(mktemp -d "${TMPDIR:-/tmp}/mesh-${component}.XXXXXX")"
    MESH_STAGE_DIRS+=("$created_dir")
    printf -v "$result_var" '%s' "$created_dir"
}

stage_cleanup() {
    local stage_dir
    for stage_dir in "${MESH_STAGE_DIRS[@]}"; do
        [ -n "$stage_dir" ] && rm -rf -- "$stage_dir"
    done
    MESH_STAGE_DIRS=()
}

mesh_sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

mesh_file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Output includes relative path, mode, and content digest. A rename, mode
# change, or content swap therefore always changes the deployment digest.
stage_manifest() {
    local stage_dir="$1" file relative mode digest
    [ -d "$stage_dir" ] || { error "stage directory not found: $stage_dir"; return 1; }

    while IFS= read -r -d '' file; do
        relative=${file#"$stage_dir"/}
        [ "$relative" = ".mesh-manifest" ] && continue
        mode=$(mesh_file_mode "$file") || return 1
        digest=$(mesh_sha256_file "$file") || return 1
        printf '%s\t%s\t%s\n' "$relative" "$mode" "$digest"
    done < <(find "$stage_dir" -type f -print0 | LC_ALL=C sort -z)
}

stage_digest() {
    local stage_dir="$1" manifest
    manifest="$(mktemp "${TMPDIR:-/tmp}/mesh-manifest.XXXXXX")"
    stage_manifest "$stage_dir" > "$manifest"
    mesh_sha256_file "$manifest"
    rm -f "$manifest"
}

stage_write_manifest() {
    local stage_dir="$1"
    stage_manifest "$stage_dir" > "$stage_dir/.mesh-manifest"
    chmod 0600 "$stage_dir/.mesh-manifest"
}

stage_manifest_validate() {
    local manifest="$1" relative mode digest
    [ -f "$manifest" ] || { error "manifest not found: $manifest"; return 1; }
    while IFS=$'\t' read -r relative mode digest; do
        [ -n "$relative" ] || continue
        case "$relative" in
            /*|*..*|*//*|.mesh-manifest) error "unsafe managed path: $relative"; return 1 ;;
        esac
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || { error "invalid managed mode for $relative: $mode"; return 1; }
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { error "invalid managed digest for $relative"; return 1; }
    done < "$manifest"
}
