#!/usr/bin/env bash
# Dependency-light offline tests. No Docker daemon or network access required.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mesh-tests.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

# shellcheck source=../lib/common.sh
source "$ROOT_DIR/bashbuild/lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$ROOT_DIR/bashbuild/lib/inventory.sh"
# shellcheck source=../lib/stage.sh
source "$ROOT_DIR/bashbuild/lib/stage.sh"

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

printf '1..23\n'
assert_success "inventory validation: two nodes" inv_validate "$ROOT_DIR/configs/examples/inventory.2node.json"
assert_success "inventory validation: three nodes" inv_validate "$ROOT_DIR/configs/examples/inventory.3node.json"

cp "$ROOT_DIR/configs/examples/inventory.2node.json" "$TEST_TMP/invalid.json"
jq '.nodes[1].name = .nodes[0].name' "$TEST_TMP/invalid.json" > "$TEST_TMP/duplicate.json"
assert_failure "inventory rejects duplicate node names" inv_validate "$TEST_TMP/duplicate.json"

jq '.nodes[0].host = "host; touch /tmp/injected"' "$ROOT_DIR/configs/examples/inventory.2node.json" > "$TEST_TMP/injection.json"
assert_failure "inventory rejects injection-shaped host values" inv_validate "$TEST_TMP/injection.json"

jq '.environment = "production"' "$ROOT_DIR/configs/examples/inventory.2node.json" > "$TEST_TMP/production-latest.json"
assert_failure "production inventory rejects latest images" inv_validate "$TEST_TMP/production-latest.json"

assert_failure "CLI rejects unknown commands" env INVENTORY="$ROOT_DIR/configs/examples/inventory.2node.json" "$ROOT_DIR/mesh.sh" unknown-command
compare_golden_inventory "$ROOT_DIR/configs/examples/inventory.2node.json"
compare_golden_inventory "$ROOT_DIR/configs/examples/inventory.3node.json"

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

cp "$ROOT_DIR/configs/examples/inventory.2node.json" "$TEST_TMP/locked.json"
mkdir "$TEST_TMP/locked.json.lock"
assert_failure "inventory mutation respects lock" env INVENTORY_LOCK_TIMEOUT=0 bash -c '
    source "$1/bashbuild/lib/common.sh"
    source "$1/bashbuild/lib/inventory.sh"
    inv_stats_set_master "$2" suomi
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

created_stage=""
stage_create created_stage unit
[ -d "$created_stage" ] || fail "stage_create creates a registered stage"
stage_cleanup
[ ! -e "$created_stage" ] || fail "stage_create creates a registered stage"
pass "stage cleanup removes registered stages"

printf '../escape\t600\t%s\n' "$(printf x | sha256sum | awk '{print $1}')" > "$TEST_TMP/unsafe.manifest"
assert_failure "managed manifest rejects traversal" stage_manifest_validate "$TEST_TMP/unsafe.manifest"

assert_success "normalized plan accepts global inventory option" \
    "$ROOT_DIR/mesh.sh" --inventory "$ROOT_DIR/configs/examples/inventory.2node.json" plan all

assert_failure "non-interactive deploy requires explicit yes" \
    "$ROOT_DIR/mesh.sh" deploy xray --node suomi --non-interactive --inventory "$ROOT_DIR/configs/examples/inventory.2node.json"

render_dir="$TEST_TMP/rendered xray"
assert_success "normalized render creates a valid managed stage" \
    "$ROOT_DIR/mesh.sh" render xray --node suomi --output "$render_dir" --inventory "$ROOT_DIR/configs/examples/inventory.2node.json"
stage_manifest_validate "$render_dir/.mesh-manifest" || fail "normalized render creates a valid managed stage"
pass "normalized render manifest validates"

jq '
    .nodes[0].protocols = ["xray", "hysteria"]
    | .nodes[0].tls_domain = "one.example.test"
    | .nodes[0].hysteria_stats_secret = "shared-secret"
    | .nodes[1].protocols = ["xray", "hysteria"]
    | .nodes[1].tls_domain = "two.example.test"
    | .nodes[1].hysteria_stats_secret = "different-secret"
' "$ROOT_DIR/configs/examples/inventory.2node.json" > "$TEST_TMP/divergent-secrets.json"
assert_failure "inventory rejects divergent Hysteria secrets" inv_validate "$TEST_TMP/divergent-secrets.json"

jq '.xray.reality.private_key = "" | .xray.reality.public_key = ""' \
    "$ROOT_DIR/configs/examples/inventory.2node.json" > "$TEST_TMP/missing-reality.json"
assert_failure "Xray deploy validation requires pre-existing Reality keys" \
    inv_validate_xray_deploy_secrets "$TEST_TMP/missing-reality.json"

jq '
    .nodes[0].protocols = ["xray", "hysteria"]
    | .nodes[0].tls_domain = "one.example.test"
    | .nodes[0].hysteria_stats_secret = ""
' "$ROOT_DIR/configs/examples/inventory.2node.json" > "$TEST_TMP/missing-hysteria-secret.json"
assert_failure "Xray deploy validation requires pre-existing Hysteria secret" \
    inv_validate_xray_deploy_secrets "$TEST_TMP/missing-hysteria-secret.json"
