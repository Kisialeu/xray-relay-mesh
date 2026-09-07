#!/usr/bin/env bash
# Deterministic local staging manifests.

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
