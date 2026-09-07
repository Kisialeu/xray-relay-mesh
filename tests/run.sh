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
# shellcheck source=../lib/stage.sh
source "$ROOT_DIR/lib/stage.sh"

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

assert_not_equal() {
    local description="$1" left="$2" right="$3"
    [ "$left" != "$right" ] || fail "$description"
    pass "$description"
}

printf '1..14\n'
assert_success "inventory validation: two nodes" inv_validate "$ROOT_DIR/examples/inventory.2node.json"
assert_success "inventory validation: three nodes" inv_validate "$ROOT_DIR/examples/inventory.3node.json"

cp "$ROOT_DIR/examples/inventory.2node.json" "$TEST_TMP/invalid.json"
jq '.nodes[1].name = .nodes[0].name' "$TEST_TMP/invalid.json" > "$TEST_TMP/duplicate.json"
assert_failure "inventory rejects duplicate node names" inv_validate "$TEST_TMP/duplicate.json"

jq '.nodes[0].host = "host; touch /tmp/injected"' "$ROOT_DIR/examples/inventory.2node.json" > "$TEST_TMP/injection.json"
assert_failure "inventory rejects injection-shaped host values" inv_validate "$TEST_TMP/injection.json"

jq '.environment = "production"' "$ROOT_DIR/examples/inventory.2node.json" > "$TEST_TMP/production-latest.json"
assert_failure "production inventory rejects latest images" inv_validate "$TEST_TMP/production-latest.json"

assert_failure "CLI rejects unknown commands" env INVENTORY="$ROOT_DIR/examples/inventory.2node.json" "$ROOT_DIR/mesh.sh" unknown-command
compare_golden_inventory "$ROOT_DIR/examples/inventory.2node.json"
compare_golden_inventory "$ROOT_DIR/examples/inventory.3node.json"

mkdir -p "$TEST_TMP/manifest/a" "$TEST_TMP/manifest/b"
printf 'first\n' > "$TEST_TMP/manifest/a/value"
printf 'second\n' > "$TEST_TMP/manifest/b/value"
manifest_before="$(stage_digest "$TEST_TMP/manifest")"
mv "$TEST_TMP/manifest/a/value" "$TEST_TMP/manifest/a/renamed"
manifest_after="$(stage_digest "$TEST_TMP/manifest")"
assert_not_equal "manifest detects renamed files" "$manifest_before" "$manifest_after"

manifest_before="$manifest_after"
mv "$TEST_TMP/manifest/a/renamed" "$TEST_TMP/manifest/swap"
mv "$TEST_TMP/manifest/b/value" "$TEST_TMP/manifest/a/renamed"
mv "$TEST_TMP/manifest/swap" "$TEST_TMP/manifest/b/value"
manifest_after="$(stage_digest "$TEST_TMP/manifest")"
assert_not_equal "manifest binds content to relative paths" "$manifest_before" "$manifest_after"

cp "$ROOT_DIR/examples/inventory.2node.json" "$TEST_TMP/locked.json"
mkdir "$TEST_TMP/locked.json.lock"
assert_failure "inventory mutation respects lock" env INVENTORY_LOCK_TIMEOUT=0 bash -c '
    source "$1/lib/common.sh"
    source "$1/lib/inventory.sh"
    inv_xray_set_reality_keys "$2" private public
' _ "$ROOT_DIR" "$TEST_TMP/locked.json"

SSH_KEY="$TEST_TMP/key with spaces"
SSH_USER=tester
PATH="$ROOT_DIR/tests/fixtures/bin:$PATH"
export SSH_KEY SSH_USER PATH
ssh_output="$(ssh_run example.test true)"
printf '%s\n' "$ssh_output" | grep -Fx "$SSH_KEY" >/dev/null \
    || fail "SSH identity path remains one argument"
pass "SSH identity path remains one argument"

local_path="$TEST_TMP/local file"
printf 'data\n' > "$local_path"
scp_output="$(scp_to example.test "$local_path" /tmp/remote-file)"
printf '%s\n' "$scp_output" | grep -Fx "$local_path" >/dev/null \
    || fail "SCP local path remains one argument"
pass "SCP local path remains one argument"

PATH="$ROOT_DIR/tests/fixtures/exec-bin:$PATH"
payload="value'; touch '$TEST_TMP/injected'; printf '"
remote_output="$(remote_bash example.test "$payload" <<'REMOTE'
printf '%s\n' "$1"
REMOTE
)"
[ "$remote_output" = "$payload" ] && [ ! -e "$TEST_TMP/injected" ] \
    || fail "remote positional arguments prevent command injection"
pass "remote positional arguments prevent command injection"
