#!/usr/bin/env bash
#
# verify-private-path.sh
#
# Confirms that a tool hostname resolves to private endpoint ENIs and that the
# TLS handshake against it succeeds with the tool's own certificate. Run this
# from inside a melt-fetcher Fargate task (via ECS Exec) once the BugRaid
# consumer-endpoint stack is in CREATE_COMPLETE.
#
# Usage:
#   ./verify-private-path.sh grafana.weworkindia.internal 3000
#   ./verify-private-path.sh jira.weworkindia.internal 443 /rest/api/2/serverInfo
#
# Exit codes:
#   0 — private path verified end-to-end
#   1 — DNS resolution failed
#   2 — DNS resolves but to a public IP (private hosted zone not attached)
#   3 — TCP reachable but TLS handshake failed (cert mismatch)
#   4 — TLS works but HTTP probe failed (auth or app-layer issue)

set -euo pipefail

HOSTNAME="${1:?usage: $0 <hostname> <port> [path]}"
PORT="${2:?usage: $0 <hostname> <port> [path]}"
PROBE_PATH="${3:-/}"

red() { printf '\033[0;31m%s\033[0m\n' "$1"; }
green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$1"; }
hr() { printf -- '─%.0s' {1..60}; echo; }

hr
echo "Verifying private path to ${HOSTNAME}:${PORT}"
hr

# 1. DNS resolution ----------------------------------------------------------
echo
echo "[1/3] DNS resolution"
if ! resolved=$(dig +short +time=2 +tries=1 "${HOSTNAME}" 2>/dev/null); then
  red "  FAIL — dig command unavailable or DNS query failed"
  exit 1
fi
if [[ -z "${resolved}" ]]; then
  red "  FAIL — ${HOSTNAME} returned NXDOMAIN"
  echo "  Check: aws route53 list-hosted-zones-by-vpc --vpc-id <bugraid-vpc>"
  echo "  Expected: a hosted zone named '${HOSTNAME}.' attached to this VPC"
  exit 1
fi

echo "  ${HOSTNAME} resolves to:"
while read -r ip; do
  [[ -z "${ip}" ]] && continue
  echo "    ${ip}"
  if [[ "${ip}" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
    green "    ✓ private RFC1918 address"
  else
    red "    ✗ ${ip} is NOT a private address"
    echo "    The private hosted zone is missing or wrong — public DNS shadowed."
    exit 2
  fi
done <<< "${resolved}"

# 2. TLS handshake -----------------------------------------------------------
echo
echo "[2/3] TLS handshake"
tls_out=$(timeout 10 openssl s_client \
  -connect "${HOSTNAME}:${PORT}" \
  -servername "${HOSTNAME}" \
  -verify_return_error \
  </dev/null 2>&1 || true)

if echo "${tls_out}" | grep -q "Verify return code: 0"; then
  green "  ✓ TLS handshake succeeded; certificate validated"
  subject=$(echo "${tls_out}" | grep -E "^subject=" | head -1 | sed 's/^subject=//')
  echo "  Cert subject: ${subject}"
elif echo "${tls_out}" | grep -q "verify error:num=10\|verify error:num=18"; then
  yellow "  ⚠ TLS handshake succeeded but certificate chain incomplete or self-signed"
  echo "  Continuing — melt-fetcher may need verify=False in dev"
elif echo "${tls_out}" | grep -q "Hostname mismatch"; then
  red "  ✗ TLS connected but cert does NOT cover ${HOSTNAME}"
  echo "  Run: openssl s_client -connect <tool-ip>:${PORT} </dev/null 2>/dev/null \\"
  echo "       | openssl x509 -noout -text | grep -A1 'Subject Alternative'"
  echo "  Then either: (a) re-deploy BugRaid stack with the actual cert-covered"
  echo "  hostname, or (b) ask the customer to add a SAN."
  exit 3
elif echo "${tls_out}" | grep -q "Connection refused\|timed out"; then
  red "  ✗ TLS connection refused or timed out"
  echo "  Likely: endpoint connection still pendingAcceptance on customer side,"
  echo "  OR customer's NLB target health-check is failing."
  exit 3
else
  red "  ✗ TLS handshake failed for unknown reason"
  echo "${tls_out}" | tail -20
  exit 3
fi

# 3. HTTP probe --------------------------------------------------------------
echo
echo "[3/3] HTTP probe (unauthenticated GET ${PROBE_PATH})"
http_status=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 5 --max-time 15 \
  "https://${HOSTNAME}:${PORT}${PROBE_PATH}" || echo "000")

case "${http_status}" in
  200|204|301|302)
    green "  ✓ HTTP ${http_status} — full path works end-to-end"
    ;;
  401|403)
    green "  ✓ HTTP ${http_status} — tool reached, auth required (expected)"
    echo "  This is normal for most tools. Use a real token to verify auth."
    ;;
  404)
    yellow "  ⚠ HTTP 404 — tool reached, but probe path ${PROBE_PATH} not found"
    echo "  Try a known path like /api/health (Grafana) or /serverInfo (Jira)."
    ;;
  000)
    red "  ✗ No HTTP response (connection failed)"
    exit 4
    ;;
  *)
    yellow "  ⚠ HTTP ${http_status} — unexpected, but at least the tool responded"
    ;;
esac

echo
hr
green "Private path verification COMPLETE for ${HOSTNAME}:${PORT}"
hr
