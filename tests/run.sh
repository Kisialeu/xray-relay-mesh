#!/usr/bin/env bash
# Dependency-light offline tests. No Docker daemon or network access required.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mesh-tests.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

# shellcheck source=../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$ROOT_DIR/lib/inventory.sh"

pass_count=0

pass() {
    pass_count=$((pass_count + 1))
    printf 'ok %d - %s\n' "$pass_count" "$1"
}

fail() {
    printf 'not ok %d - %s\n' "$((pass_count + 1))" "$1" >&2
    exit 1
}

assert_success() {
    local description="$1"
    shift
    "$@" >/dev/null 2>&1 || fail "$description"
    pass "$description"
}

assert_failure() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$description"
    fi
    pass "$description"
}

compare_golden_inventory() {
    local fixture="$1" fixture_name actual expected
    fixture_name="$(basename "$fixture" .json)"
    actual="$TEST_TMP/$fixture_name"
    expected="$ROOT_DIR/tests/golden/$fixture_name"

    "$ROOT_DIR/tests/update-golden.sh" "$fixture" "$actual"
    diff -ru "$expected" "$actual" >/dev/null || {
        diff -ru "$expected" "$actual" >&2 || true
        fail "golden rendering: $fixture_name"
    }
    pass "golden rendering: $fixture_name"
}

printf '1..6\n'
assert_success "inventory validation: two nodes" inv_validate "$ROOT_DIR/examples/inventory.2node.json"
assert_success "inventory validation: three nodes" inv_validate "$ROOT_DIR/examples/inventory.3node.json"

cp "$ROOT_DIR/examples/inventory.2node.json" "$TEST_TMP/invalid.json"
jq '.nodes[1].name = .nodes[0].name' "$TEST_TMP/invalid.json" > "$TEST_TMP/duplicate.json"
assert_failure "inventory rejects duplicate node names" inv_validate "$TEST_TMP/duplicate.json"

assert_failure "CLI rejects unknown commands" env INVENTORY="$ROOT_DIR/examples/inventory.2node.json" "$ROOT_DIR/mesh.sh" unknown-command
compare_golden_inventory "$ROOT_DIR/examples/inventory.2node.json"
compare_golden_inventory "$ROOT_DIR/examples/inventory.3node.json"
