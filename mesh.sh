#!/usr/bin/env bash
# Stable repository entrypoint for the Bash deployment framework.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT_DIR/bashbuild/mesh.sh" "$@"
