#!/usr/bin/env bash
# Read-only repository validation. This script never contacts remote hosts.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

mapfile -d '' shell_files < <(find "$ROOT_DIR" -type f -name '*.sh' -not -path '*/.git/*' -print0)

printf 'Checking Bash syntax (%d files)\n' "${#shell_files[@]}"
bash -n "${shell_files[@]}"

if command -v shellcheck >/dev/null 2>&1; then
    printf 'Running shellcheck\n'
    shellcheck -x -S warning "${shell_files[@]}"
else
    printf 'WARN: shellcheck is not installed; skipped\n' >&2
fi

if command -v shfmt >/dev/null 2>&1; then
    printf 'Running shfmt\n'
    shfmt -d "${shell_files[@]}"
else
    printf 'WARN: shfmt is not installed; skipped\n' >&2
fi

printf 'Compiling Python sources\n'
PYTHONPYCACHEPREFIX="$(mktemp -d "${TMPDIR:-/tmp}/mesh-pycache.XXXXXX")"
trap 'rm -rf "$PYTHONPYCACHEPREFIX"' EXIT
export PYTHONPYCACHEPREFIX
python3 -m compileall -q "$ROOT_DIR/services/stats/src" "$ROOT_DIR/services/web/app"

printf 'Running offline tests\n'
"$ROOT_DIR/tests/run.sh"

printf 'All available checks passed\n'
