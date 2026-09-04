#!/usr/bin/env bash
# Full CloudFront subscription server setup:
#   1. ACM certificate  (us-east-1, DNS-validated via Route 53)
#   2. CloudFront distribution  (origin: ORIGIN_HOST:8080, custom verify header)
#   3. Route 53 alias record  -> CloudFront
#   4. Origin server iptables firewall  (DOCKER-USER chain; skip with SKIP_FIREWALL=1)
#   5. End-to-end smoke test
#
# domain/zone_domain/origin host/origin_verify_secret now come from
# inventory.json's "subs" block. Ported from the old certificate.sh /
# certificate_paravozik.sh (those two were byte-identical except for example
# domains in comments).
#
# Usage:
#   ./setup_cdn_cert.sh [inventory.json]
#
# Optional env:
#   ORIGIN_VERIFY_SECRET  - overrides inventory.json's subs.origin_verify_secret
#   SSH_KEY, SSH_USER     - override inventory.json's subs.ssh_key/subs.ssh_user
#                            (used to configure the origin firewall)
#   SKIP_FIREWALL         - set to 1 to skip the iptables step (default: 1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/inventory.sh
source "$SCRIPT_DIR/../lib/inventory.sh"

# ============================================================
# LOGGING - thin wrappers over common.sh so the phase functions below
# (ported verbatim from the old script) don't need to change at all.
# ============================================================
ok()    { success "$@"; }
err()   { error "$@"; exit 1; }
step()  { echo ""; echo "==== $* ===="; }

# ============================================================
# ARGS / ENV
# ============================================================
INVENTORY="${1:-$MESH_DIR/inventory.json}"
inv_validate "$INVENTORY" || exit 1

DOMAIN="$(inv_subs_domain "$INVENTORY")"
ZONE_DOMAIN="$(inv_subs_zone_domain "$INVENTORY")"
ORIGIN_HOST="$(inv_subs_caddy_host "$INVENTORY")"
[ -n "$DOMAIN" ]      || err "subs.domain not set in $INVENTORY"
[ -n "$ZONE_DOMAIN" ] || err "subs.zone_domain not set in $INVENTORY"
[ -n "$ORIGIN_HOST" ] || err "subs.caddy_host not set in $INVENTORY"

: "${ORIGIN_VERIFY_SECRET:=$(inv_subs_origin_verify_secret "$INVENTORY")}"
[ -n "$ORIGIN_VERIFY_SECRET" ] || err "subs.origin_verify_secret not set in $INVENTORY (or export ORIGIN_VERIFY_SECRET)"
mesh_resolve_subs_ssh "$INVENTORY"
SKIP_FIREWALL="${SKIP_FIREWALL:-1}"

# CloudFront and WAF for CloudFront must always be in us-east-1
CF_REGION="us-east-1"

# ============================================================
# HELPERS
# ============================================================
get_account_id() {
    aws sts get-caller-identity --query Account --output text
}

get_zone_id() {
    local zone_id
    zone_id=$(aws route53 list-hosted-zones-by-name \
        --dns-name "${ZONE_DOMAIN}" \
        --query "HostedZones[0].Id" \
        --output text | sed 's|/hostedzone/||')
    if [[ -z "${zone_id}" || "${zone_id}" == "None" ]]; then
        err "Hosted zone not found for ${ZONE_DOMAIN}"
    fi
    echo "${zone_id}"
}

# ============================================================
# PHASE 1: ACM CERTIFICATE
# ============================================================
phase_cert() {
    step "ACM certificate for ${DOMAIN} (region: ${CF_REGION})"

    local existing_arn
    existing_arn=$(aws acm list-certificates \
        --region "${CF_REGION}" \
        --certificate-statuses PENDING_VALIDATION ISSUED \
        --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" \
        --output text)

    if [[ -n "${existing_arn}" && "${existing_arn}" != "None" ]]; then
        ok "Existing certificate found: ${existing_arn}"
        CERT_ARN="${existing_arn}"
        return
    fi

    local zone_id
    zone_id=$(get_zone_id)
    info "Zone ID: ${zone_id}"

    local idem_token
    idem_token=$(printf '%s' "${DOMAIN}" | sha256sum | cut -c1-32)

    CERT_ARN=$(aws acm request-certificate \
        --domain-name "${DOMAIN}" \
        --validation-method DNS \
        --idempotency-token "${idem_token}" \
        --region "${CF_REGION}" \
        --query 'CertificateArn' \
        --output text)
    info "Certificate requested: ${CERT_ARN}"

    # Wait for ACM to populate the validation DNS record (up to 100s)
    local record="null"
    for i in $(seq 1 20); do
        record=$(aws acm describe-certificate \
            --certificate-arn "${CERT_ARN}" \
            --region "${CF_REGION}" \
            --query 'Certificate.DomainValidationOptions[0].ResourceRecord' \
            --output json)
        [[ "${record}" != "null" ]] && break
        info "Validation record not yet available, retrying (${i}/20)..."
        sleep 5
    done
    [[ "${record}" == "null" ]] && err "ACM did not return validation record after 100s"

    local rr_name rr_value
    rr_name=$(echo "${record}" | jq -r '.Name')
    rr_value=$(echo "${record}" | jq -r '.Value')
    info "Upserting CNAME: ${rr_name} -> ${rr_value}"

    local change_id
    change_id=$(aws route53 change-resource-record-sets \
        --hosted-zone-id "${zone_id}" \
        --change-batch "$(jq -n \
            --arg name "${rr_name}" \
            --arg value "${rr_value}" \
            '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":$name,"Type":"CNAME","TTL":300,"ResourceRecords":[{"Value":$value}]}}]}')" \
        --query 'ChangeInfo.Id' \
        --output text)

    info "Waiting for Route 53 propagation (${change_id})..."
    aws route53 wait resource-record-sets-changed --id "${change_id}"

    info "Waiting for ACM validation (up to ~5 min after DNS propagates)..."
    aws acm wait certificate-validated \
        --certificate-arn "${CERT_ARN}" \
        --region "${CF_REGION}"

    ok "Certificate validated: ${CERT_ARN}"
}

# ============================================================
# PHASE 2: CLOUDFRONT DISTRIBUTION
# ============================================================
phase_cloudfront() {
    step "CloudFront distribution for ${DOMAIN} -> ${ORIGIN_HOST}:8080"

    # Check if a distribution for this CNAME already exists
    local existing_id
    existing_id=$(aws cloudfront list-distributions \
        --query "DistributionList.Items[?Aliases.Items!=null] | [?contains(Aliases.Items,'${DOMAIN}')].Id | [0]" \
        --output text 2>/dev/null || true)

    if [[ -n "${existing_id}" && "${existing_id}" != "None" ]]; then
        ok "Existing distribution found: ${existing_id}"
        DIST_ID="${existing_id}"
        DIST_DOMAIN=$(aws cloudfront get-distribution \
            --id "${DIST_ID}" \
            --query 'Distribution.DomainName' \
            --output text)
        ok "Distribution domain: ${DIST_DOMAIN}"
        return
    fi

    # AWS managed policy IDs (stable, global)
    #   CachingDisabled : 4135ea2d-6df8-44a3-9df3-4b5a84be39ad
    #   AllViewer       : 216adef6-5c7f-47e4-b989-5492eafa07d3
    local caller_ref
    caller_ref=$(printf '%s:%s' "${DOMAIN}" "${ORIGIN_HOST}" | sha256sum | cut -c1-16)

    local dist_config
    dist_config=$(jq -n \
        --arg ref        "${caller_ref}" \
        --arg domain     "${DOMAIN}" \
        --arg origin     "${ORIGIN_HOST}" \
        --arg secret     "${ORIGIN_VERIFY_SECRET}" \
        --arg cert_arn   "${CERT_ARN}" \
        '{
          "CallerReference": $ref,
          "Comment": ("CloudFront sub server: " + $domain),
          "Enabled": true,
          "HttpVersion": "http2and3",
          "Aliases": {
            "Quantity": 1,
            "Items": [$domain]
          },
          "Origins": {
            "Quantity": 1,
            "Items": [{
              "Id": "sub-origin",
              "DomainName": $origin,
              "CustomOriginConfig": {
                "HTTPPort": 8080,
                "HTTPSPort": 443,
                "OriginProtocolPolicy": "http-only",
                "OriginReadTimeout": 30,
                "OriginKeepaliveTimeout": 5,
                "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]}
              },
              "CustomHeaders": {
                "Quantity": 1,
                "Items": [{"HeaderName": "X-Origin-Verify", "HeaderValue": $secret}]
              }
            }]
          },
          "DefaultCacheBehavior": {
            "TargetOriginId": "sub-origin",
            "ViewerProtocolPolicy": "redirect-to-https",
            "AllowedMethods": {
              "Quantity": 2,
              "Items": ["GET", "HEAD"],
              "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}
            },
            "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
            "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3",
            "Compress": true
          },
          "ViewerCertificate": {
            "ACMCertificateArn": $cert_arn,
            "SSLSupportMethod": "sni-only",
            "MinimumProtocolVersion": "TLSv1.2_2021",
            "Certificate": $cert_arn,
            "CertificateSource": "acm"
          },
          "PriceClass": "PriceClass_All"
        }')

    local result
    result=$(aws cloudfront create-distribution \
        --distribution-config "${dist_config}")

    DIST_ID=$(echo "${result}" | jq -r '.Distribution.Id')
    DIST_DOMAIN=$(echo "${result}" | jq -r '.Distribution.DomainName')
    ok "Distribution created: ${DIST_ID}"
    ok "Distribution domain:  ${DIST_DOMAIN}"

    info "Waiting for distribution to deploy (typically 3-8 min)..."
    aws cloudfront wait distribution-deployed --id "${DIST_ID}"
    ok "Distribution deployed"
}

# ============================================================
# PHASE 3: ROUTE 53 ALIAS
# ============================================================
phase_dns() {
    step "Route 53 alias ${DOMAIN} -> ${DIST_DOMAIN}"

    local zone_id
    zone_id=$(get_zone_id)

    # CloudFront hosted zone ID is fixed for all distributions
    local cf_hosted_zone_id="Z2FDTNDATAQYW2"

    # Check if the record already points to this distribution
    local existing_target
    existing_target=$(aws route53 list-resource-record-sets \
        --hosted-zone-id "${zone_id}" \
        --query "ResourceRecordSets[?Name=='${DOMAIN}.' && Type=='A'].AliasTarget.DNSName | [0]" \
        --output text 2>/dev/null || true)

    if [[ "${existing_target}" == "${DIST_DOMAIN}." || "${existing_target}" == "${DIST_DOMAIN}" ]]; then
        ok "DNS alias already correct: ${DOMAIN} -> ${DIST_DOMAIN}"
        return
    fi

    local change_id
    change_id=$(aws route53 change-resource-record-sets \
        --hosted-zone-id "${zone_id}" \
        --change-batch "$(jq -n \
            --arg name     "${DOMAIN}" \
            --arg dns_name "${DIST_DOMAIN}" \
            --arg hz_id    "${cf_hosted_zone_id}" \
            '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":$name,"Type":"A","AliasTarget":{"HostedZoneId":$hz_id,"DNSName":$dns_name,"EvaluateTargetHealth":false}}}]}')" \
        --query 'ChangeInfo.Id' \
        --output text)

    info "Waiting for Route 53 propagation (${change_id})..."
    aws route53 wait resource-record-sets-changed --id "${change_id}"
    ok "DNS alias set: ${DOMAIN} -> ${DIST_DOMAIN}"
}

# ============================================================
# PHASE 4: ORIGIN SERVER IPTABLES FIREWALL (DOCKER-USER chain)
# Restricts port 8080 to CloudFront CIDRs only so bare-IP access is impossible.
# Uses DOCKER-USER chain which Docker consults before its own DOCKER chain.
# ============================================================
phase_firewall() {
    step "Origin server iptables firewall (${ORIGIN_HOST})"

    if [[ "${SKIP_FIREWALL}" == "1" ]]; then
        warn "SKIP_FIREWALL=1 - skipping firewall step"
        return
    fi

    if [[ ! -f "${SSH_KEY}" ]]; then
        warn "SSH_KEY not found at ${SSH_KEY} - skipping firewall step (set SSH_KEY env var)"
        return
    fi

    info "Fetching CloudFront CIDR list from AWS..."
    local cf_cidrs
    cf_cidrs=$(curl -sf https://ip-ranges.amazonaws.com/ip-ranges.json \
        | jq -r '.prefixes[] | select(.service=="CLOUDFRONT") | .ip_prefix')

    # A malformed/empty response would otherwise still reach the DROP-all
    # rule appended below, but only after emitting a bad `-s ''` ACCEPT rule
    # first - abort instead of risking a fail-open (or half-applied) firewall.
    [[ -z "${cf_cidrs}" ]] && err "No CloudFront CIDRs returned from AWS - aborting firewall step rather than risk a fail-open rule"

    local cidr_count
    cidr_count=$(echo "${cf_cidrs}" | wc -l | tr -d ' ')
    info "${cidr_count} CloudFront IPv4 CIDRs fetched"

    # Build script: flush old CF rules, add fresh ones, drop everything else, persist
    local fw_script
    fw_script=$(cat << 'FWSCRIPT_END'
#!/bin/bash
set -euo pipefail
PORT=8080

echo "[INFO ] Removing stale CF rules from DOCKER-USER for port ${PORT}..."
# Delete all rules matching dport 8080 with a source (the CF ACCEPT rules)
# Loop until none remain (iptables -D removes one at a time)
while iptables -L DOCKER-USER -n 2>/dev/null | grep -q "tcp dpt:${PORT}"; do
    rule=$(iptables -L DOCKER-USER -n --line-numbers 2>/dev/null \
        | awk -v p="${PORT}" '$0 ~ "tcp dpt:"p {print $1; exit}')
    [ -z "$rule" ] && break
    iptables -D DOCKER-USER "$rule" 2>/dev/null || break
done

echo "[INFO ] Adding CloudFront ACCEPT rules..."
FWSCRIPT_END
)

    # One ACCEPT per CloudFront CIDR, inserted before any existing DROP for this port
    while IFS= read -r cidr; do
        fw_script+=$'\n'"iptables -I DOCKER-USER -p tcp -s '${cidr}' --dport 8080 -j ACCEPT"
    done <<< "${cf_cidrs}"

    # DROP everything else to port 8080
    fw_script+=$'\n''iptables -A DOCKER-USER -p tcp --dport 8080 -j DROP'
    fw_script+=$'\n''echo "[INFO ] Persisting rules..."'
    fw_script+=$'\n''apt-get install -y iptables-persistent -qq 2>/dev/null || true'
    fw_script+=$'\n''iptables-save > /etc/iptables/rules.v4'
    fw_script+=$'\n''echo "[OK   ] Firewall configured: port 8080 restricted to CloudFront CIDRs"'
    fw_script+=$'\n''iptables -L DOCKER-USER -n | grep -c "ACCEPT" | xargs -I{} echo "[OK   ] {} ACCEPT rules active"'

    ssh -i "${SSH_KEY}" \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes \
        "${SSH_USER}@${ORIGIN_HOST}" \
        "bash -s" <<< "${fw_script}"

    ok "Origin server firewall configured"
}

# ============================================================
# PHASE 5: SMOKE TEST
# ============================================================
phase_verify() {
    step "End-to-end smoke test"

    local url="https://${DOMAIN}/"

    # Without correct UA -> Caddy returns 404
    local http_code
    http_code=$(curl -sf \
        --max-time 15 \
        --retry 3 \
        --retry-delay 5 \
        --write-out '%{http_code}' \
        --output /dev/null \
        "${url}" 2>/dev/null || echo "FAIL")

    if [[ "${http_code}" == "404" || "${http_code}" == "403" ]]; then
        ok "Smoke test passed: ${url} returned ${http_code} (no UA, expected)"
    elif [[ "${http_code}" == "FAIL" ]]; then
        warn "Smoke test: could not reach ${url} - distribution may still be propagating"
        warn "Re-run: curl -v ${url}"
    else
        warn "Smoke test: unexpected HTTP ${http_code} from ${url} (expected 403/404)"
    fi

    # With a proxy-client UA -> 404 (no token in path, but UA passes the allowlist)
    local http_code_ua
    http_code_ua=$(curl -sf \
        -A "v2rayNG/1.8.0" \
        --max-time 15 \
        --retry 2 \
        --write-out '%{http_code}' \
        --output /dev/null \
        "${url}" 2>/dev/null || echo "FAIL")

    if [[ "${http_code_ua}" == "404" ]]; then
        ok "UA allowlist working: proxy UA returned 404 (no token, expected)"
    elif [[ "${http_code_ua}" == "FAIL" ]]; then
        warn "Smoke test with UA failed - check CloudFront status"
    else
        warn "Unexpected response ${http_code_ua} with proxy UA"
    fi

    echo ""
    echo "To test with a real token:"
    echo "  curl -A 'v2rayNG/1.8.0' https://${DOMAIN}/<40-char-token>"
    echo "  (should return base64 content, HTTP 200)"
}

# ============================================================
# MAIN
# ============================================================
main() {
    echo ""
    echo "CloudFront setup: ${DOMAIN} -> https://${ORIGIN_HOST}:8080"
    echo "Region: ${CF_REGION}  |  Zone: ${ZONE_DOMAIN}"
    echo ""

    for cmd in aws jq curl sha256sum; do
        command -v "${cmd}" >/dev/null 2>&1 || err "Required command not found: ${cmd}"
    done

    CERT_ARN=""
    DIST_ID=""
    DIST_DOMAIN=""

    phase_cert
    phase_cloudfront
    phase_dns
    phase_firewall
    phase_verify

    echo ""
    echo "================================================"
    echo " Setup complete"
    echo " Domain:       https://${DOMAIN}"
    echo " Distribution: ${DIST_ID}"
    echo " Certificate:  ${CERT_ARN}"
    echo "================================================"
    echo ""
    echo "Next: start Caddy on ${ORIGIN_HOST}:8080"
    echo "  cd caddy && docker compose up -d"
    echo ""
    echo "Run relay-mesh/mesh.sh (deploy Xray/relay, then subs-generate + subs-sync)"
    echo "to bring up the nodes this CDN fronts and populate subscriptions."
}

main "$@"
