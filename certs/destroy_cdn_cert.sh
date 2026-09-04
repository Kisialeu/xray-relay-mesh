#!/usr/bin/env bash
# Tear down AWS infrastructure created by setup_cdn_cert.sh:
#   - CloudFront distribution (disabled, then deleted)
#   - ACM certificate (deleted)
#   - Route 53 alias record (deleted)
#
# Does NOT touch servers, Docker containers, or firewall rules.
#
# domain/zone_domain/origin host come from inventory.json's "subs" block -
# same source of truth as setup_cdn_cert.sh, so teardown always targets
# whatever setup last created.
#
# Usage:
#   ./destroy_cdn_cert.sh [inventory.json]

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

INVENTORY="${1:-$MESH_DIR/inventory.json}"
inv_validate "$INVENTORY" || exit 1

DOMAIN="$(inv_subs_domain "$INVENTORY")"
ZONE_DOMAIN="$(inv_subs_zone_domain "$INVENTORY")"
ORIGIN_HOST="$(inv_subs_caddy_host "$INVENTORY")"
[ -n "$DOMAIN" ]      || err "subs.domain not set in $INVENTORY"
[ -n "$ZONE_DOMAIN" ] || err "subs.zone_domain not set in $INVENTORY"
[ -n "$ORIGIN_HOST" ] || err "subs.caddy_host not set in $INVENTORY"

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
        warn "Hosted zone not found for ${ZONE_DOMAIN} - skipping DNS step"
        echo ""
        return
    fi
    echo "${zone_id}"
}

# ============================================================
# CONFIRM
# ============================================================
confirm() {
    echo ""
    echo "This will permanently delete:"
    echo "  - CloudFront distribution for ${DOMAIN}"
    echo "  - ACM certificate for ${DOMAIN} (us-east-1)"
    echo "  - Route 53 alias record ${DOMAIN} -> CloudFront"
    echo ""
    read -r -p "Type the domain to confirm deletion [${DOMAIN}]: " confirm_domain
    if [[ "${confirm_domain}" != "${DOMAIN}" ]]; then
        echo "Aborted."
        exit 0
    fi
}

# ============================================================
# PHASE 1: ROUTE 53 ALIAS
# ============================================================
destroy_dns() {
    step "Route 53 alias for ${DOMAIN}"

    local zone_id
    zone_id=$(get_zone_id)
    [ -z "${zone_id}" ] && return

    local current_dns
    current_dns=$(aws route53 list-resource-record-sets \
        --hosted-zone-id "${zone_id}" \
        --query "ResourceRecordSets[?Name=='${DOMAIN}.' && Type=='A'].AliasTarget.DNSName | [0]" \
        --output text 2>/dev/null || true)

    if [[ -z "${current_dns}" || "${current_dns}" == "None" ]]; then
        ok "No A alias record found for ${DOMAIN} - skipping"
        return
    fi

    info "Deleting alias ${DOMAIN} -> ${current_dns}..."
    local cf_hosted_zone_id="Z2FDTNDATAQYW2"

    local change_id
    change_id=$(aws route53 change-resource-record-sets \
        --hosted-zone-id "${zone_id}" \
        --change-batch "$(jq -n \
            --arg name     "${DOMAIN}" \
            --arg dns_name "${current_dns}" \
            --arg hz_id    "${cf_hosted_zone_id}" \
            '{"Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":$name,"Type":"A","AliasTarget":{"HostedZoneId":$hz_id,"DNSName":$dns_name,"EvaluateTargetHealth":false}}}]}')" \
        --query 'ChangeInfo.Id' \
        --output text)

    aws route53 wait resource-record-sets-changed --id "${change_id}"
    ok "DNS alias deleted"
}

# ============================================================
# PHASE 2: CLOUDFRONT DISTRIBUTION
# CloudFront requires: disable -> wait deployed -> delete
# ============================================================
destroy_cloudfront() {
    step "CloudFront distribution for ${DOMAIN}"

    local dist_id
    dist_id=$(aws cloudfront list-distributions \
        --query "DistributionList.Items[?Aliases.Items!=null] | [?contains(Aliases.Items,'${DOMAIN}')].Id | [0]" \
        --output text 2>/dev/null || true)

    if [[ -z "${dist_id}" || "${dist_id}" == "None" ]]; then
        ok "No distribution found for ${DOMAIN} - skipping"
        return
    fi

    info "Found distribution: ${dist_id}"

    local etag config
    etag=$(aws cloudfront get-distribution-config \
        --id "${dist_id}" \
        --query 'ETag' \
        --output text)
    config=$(aws cloudfront get-distribution-config \
        --id "${dist_id}" \
        --query 'DistributionConfig' \
        --output json)

    local enabled
    enabled=$(echo "${config}" | jq -r '.Enabled')

    if [[ "${enabled}" == "true" ]]; then
        info "Disabling distribution (required before deletion)..."
        local disabled_config
        disabled_config=$(echo "${config}" | jq '.Enabled = false')

        etag=$(aws cloudfront update-distribution \
            --id "${dist_id}" \
            --distribution-config "${disabled_config}" \
            --if-match "${etag}" \
            --query 'ETag' \
            --output text)

        info "Waiting for distribution to finish disabling (2-5 min)..."
        aws cloudfront wait distribution-deployed --id "${dist_id}"
        ok "Distribution disabled"
    else
        info "Distribution already disabled"
    fi

    etag=$(aws cloudfront get-distribution-config \
        --id "${dist_id}" \
        --query 'ETag' \
        --output text)

    info "Deleting distribution ${dist_id}..."
    aws cloudfront delete-distribution \
        --id "${dist_id}" \
        --if-match "${etag}"
    ok "CloudFront distribution deleted"
}

# ============================================================
# PHASE 3: ACM CERTIFICATE
# ============================================================
destroy_cert() {
    step "ACM certificate for ${DOMAIN}"

    local cert_arn
    cert_arn=$(aws acm list-certificates \
        --region "${CF_REGION}" \
        --certificate-statuses PENDING_VALIDATION ISSUED \
        --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" \
        --output text 2>/dev/null || true)

    if [[ -z "${cert_arn}" || "${cert_arn}" == "None" ]]; then
        ok "No certificate found for ${DOMAIN} - skipping"
        return
    fi

    info "Deleting certificate ${cert_arn}..."
    aws acm delete-certificate \
        --certificate-arn "${cert_arn}" \
        --region "${CF_REGION}"
    ok "Certificate deleted"
}

# ============================================================
# MAIN
# ============================================================
main() {
    echo ""
    echo "AWS infrastructure teardown for: ${DOMAIN}"
    echo "Zone: ${ZONE_DOMAIN}  |  Origin: ${ORIGIN_HOST}  |  Region: ${CF_REGION}"

    for cmd in aws jq; do
        command -v "${cmd}" >/dev/null 2>&1 || err "Required command not found: ${cmd}"
    done

    confirm

    # Order matters: DNS first (clients get NXDOMAIN immediately),
    # then CF (must disable before delete), then cert.
    destroy_dns
    destroy_cloudfront
    destroy_cert

    echo ""
    echo "================================================"
    echo " Teardown complete"
    echo " ${DOMAIN} AWS infrastructure removed"
    echo ""
    echo " Servers and Docker containers are untouched."
    echo " To re-create: bash setup_cdn_cert.sh $INVENTORY"
    echo "================================================"
}

main "$@"
