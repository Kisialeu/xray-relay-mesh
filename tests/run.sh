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
# shellcheck source=../bashbuild/components/caddy/stage.sh
source "$ROOT_DIR/bashbuild/components/caddy/stage.sh"
# shellcheck source=../bashbuild/components/subscriptions/sync.sh
source "$ROOT_DIR/bashbuild/components/subscriptions/sync.sh"
# shellcheck source=../bashbuild/components/subscriptions/render.sh
source "$ROOT_DIR/bashbuild/components/subscriptions/render.sh"

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

printf '1..40\n'
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

printf 'q\n' | INVENTORY="$ROOT_DIR/configs/examples/inventory.2node.json" "$ROOT_DIR/mesh.sh" \
    | grep -F 'Xray Relay Mesh' >/dev/null || fail "no-argument CLI opens interactive UI"
pass "no-argument CLI opens interactive UI"

[ "$(inv_subs_content_deploy_dir "$ROOT_DIR/configs/examples/inventory.2node.json")" = "/opt/caddy-subs-content" ] \
    || fail "subscription content has a separate deployment root"
pass "subscription content has a separate deployment root"

jq '.subs.origin_verify_secret = "fixture-origin-secret"' \
    "$ROOT_DIR/configs/examples/inventory.2node.json" > "$TEST_TMP/caddy-inventory.json"
caddy_stage=""
stage_create caddy_stage caddy
caddy_render_stage "$TEST_TMP/caddy-inventory.json" "$caddy_stage"
[ "$(mesh_file_mode "$caddy_stage/.env")" = 600 ] \
    || fail "Caddy secret environment uses mode 0600"
pass "Caddy secret environment uses mode 0600"
stage_cleanup

generated_dir="$TEST_TMP/generated"
token=0123456789abcdef0123456789abcdef01234567
mkdir -p "$generated_dir/user"
printf '%s\n' "$token" > "$generated_dir/user/sub.token"
printf 'encoded\n' > "$generated_dir/user/sub.b64"
printf 'https://sub.example.test/%s\n' "$token" > "$generated_dir/user/sub.url"
printf '{"type":"vless","tag":"vless-fixture"}\n' > "$generated_dir/user/sub.singbox.json"
printf '{"Name":"Xray Relay Mesh","RemoteDNSType":"DoU","RemoteDNSIP":"172.29.0.10"}\n' > "$generated_dir/user/sub.incy.json"
printf 'private-link\n' > "$generated_dir/user/sub.links"
subscriptions_stage=""
stage_create subscriptions_stage subscriptions
subscriptions_render_stage "$generated_dir" "$subscriptions_stage"
stage_manifest_validate "$subscriptions_stage/.mesh-manifest" \
    || fail "subscription sync stages an explicit public-file manifest"
[ -f "$subscriptions_stage/$token/sub.b64" ] \
    && [ -f "$subscriptions_stage/$token/sub.singbox.json" ] \
    && [ -f "$subscriptions_stage/$token/sub.incy.json" ] \
    && [ ! -e "$subscriptions_stage/$token/sub.links" ] \
    && [ ! -e "$subscriptions_stage/$token/sub.token" ] \
    || fail "subscription sync stages an explicit public-file manifest"
pass "subscription sync stages an explicit public-file manifest"
stage_cleanup

singbox_vless=$(build_singbox_vless_outbound fixture-vless fixture-uuid 198.51.100.10 443 fixture-pubkey dl.google.com 0123456789abcdef firefox)
singbox_hysteria=$(build_singbox_hysteria2_outbound fixture-hysteria user@example.test fixture-uuid 198.51.100.10 443 hy.example.test fixture-obfs)
singbox_config=$(build_singbox_config 172.29.0.10 "[$singbox_vless,$singbox_hysteria]")
printf '%s\n' "$singbox_config" | jq -e '
    .dns.servers[0].address == "172.29.0.10"
    and .dns.servers[0].detour == "proxy"
    and .dns.rules[0].action == "route"
    and .dns.rules[0].server == "adguard"
    and (.outbounds | map(.tag) | index("proxy")) != null
    and (.outbounds[] | select(.tag == "fixture-vless") | .packet_encoding == "xudp")
    and (.outbounds[] | select(.tag == "fixture-hysteria") | .password == "user@example.test:fixture-uuid")
    and (.outbounds[] | select(.tag == "fixture-hysteria") | .obfs.type == "salamander")
    and .route.final == "proxy"
' >/dev/null || fail "sing-box profile contains proxy DNS and client outbounds"
pass "sing-box profile contains proxy DNS and client outbounds"

grep -n '@singbox_request' "$ROOT_DIR/services/caddy/Caddyfile" | cut -d: -f1 | {
    read -r singbox_line
    sub_line=$(grep -n '@sub_request' "$ROOT_DIR/services/caddy/Caddyfile" | head -n1 | cut -d: -f1)
    [ "$singbox_line" -lt "$sub_line" ]
} || fail "Caddy routes sing-box clients before legacy subscriptions"
pass "Caddy routes sing-box clients before legacy subscriptions"

grep -F 'sub.singbox.json' "$ROOT_DIR/services/caddy/Caddyfile" >/dev/null \
    || fail "Caddy serves the sing-box JSON subscription"
pass "Caddy serves the sing-box JSON subscription"

incy_routing=$(build_incy_routing_profile 172.29.0.10)
printf '%s\n' "$incy_routing" | jq -e '.GlobalProxy == "true" and .RemoteDNSType == "DoU" and .RemoteDNSIP == "172.29.0.10" and (.BlockSites | index("geosite:category-ads-all")) != null' >/dev/null \
    || fail "INCY autorouting profile forces remote AdGuard DNS"
pass "INCY autorouting profile forces remote AdGuard DNS"

grep -F 'header autorouting "incy://autorouting/onadd/https://{$SUB_DOMAIN}' "$ROOT_DIR/services/caddy/Caddyfile" >/dev/null \
    || fail "Caddy advertises the INCY autorouting profile"
pass "Caddy advertises the INCY autorouting profile"

grep -F 'docker run --rm --network none' "$ROOT_DIR/bashbuild/components/xray/verify.sh" >/dev/null \
    || fail "Xray staged validation does not create a Docker network"
pass "Xray staged validation does not create a Docker network"

grep -F 'deadline=$((SECONDS + $1))' "$ROOT_DIR/bashbuild/components/xray/verify.sh" >/dev/null \
    || fail "Xray statistics verification waits for endpoint readiness"
pass "Xray statistics verification waits for endpoint readiness"

grep -F 'xray_cleanup_failed_initial' "$ROOT_DIR/bashbuild/components/xray/deploy.sh" >/dev/null \
    || fail "Xray first-deployment failures clean mesh containers"
pass "Xray first-deployment failures clean mesh containers"

if rg -n 'success .*sub_domain.*token|success .*https://.*\$token' \
    "$ROOT_DIR/bashbuild/components/subscriptions/render.sh" >/dev/null; then
    fail "subscription generation does not log tokenized URLs"
fi
pass "subscription generation does not log tokenized URLs"

assert_failure "AdGuard UI command requires a node" \
    "$ROOT_DIR/mesh.sh" adguard ui --inventory "$ROOT_DIR/configs/examples/inventory.2node.json"
grep -F '127.0.0.1:${LOCAL_PORT}:127.0.0.1:3000' \
    "$ROOT_DIR/infrastructure/host/adguard_ui.sh" >/dev/null \
    || fail "AdGuard UI tunnel forwards the remote loopback port"
pass "AdGuard UI tunnel forwards the remote loopback port"

[ "$(printf 'hello' | mesh_base64_noline)" = "aGVsbG8=" ] \
    || fail "base64 helper emits portable newline-free output"
pass "base64 helper emits portable newline-free output"

grep -E 'header profile-update-interval "(24|\{\$SUB_PROFILE_UPDATE_INTERVAL\})"' "$ROOT_DIR/services/caddy/Caddyfile" >/dev/null \
    && grep -F 'header subscription-userinfo "0"' "$ROOT_DIR/services/caddy/Caddyfile" >/dev/null \
    && grep -F 'header_regexp client X-Client (?i)^INCY$' "$ROOT_DIR/services/caddy/Caddyfile" >/dev/null \
    || fail "Caddy exposes INCY metadata and x-client fallback"
pass "Caddy exposes INCY metadata and x-client fallback"
