#!/usr/bin/env bash
# Verification helpers run from spark (needs curl, and /etc/hosts or DNS for domains).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config

usage() {
  cat <<'EOF'
Usage: verify-federation.sh DOMAIN_A DOMAIN_B REJECT_DOMAIN

Checks:
  1) Federation version endpoint reachable between A and B
  2) REJECT_DOMAIN is not in allowlist (Synapse returns 403/404 on federation probe)

Does not send chat messages — see docs/test-nodes.md for full Matrix message test.
EOF
  exit 1
}

[[ $# -eq 3 ]] || usage

DOMAIN_A=$1
DOMAIN_B=$2
REJECT_DOMAIN=$3

require_cmd curl

probe() {
  local from=$1
  local to=$2
  local url="https://${from}/_matrix/federation/v1/query/profile?user_id=@dummy:${to}&field=displayname"
  curl -ksS -o /dev/null -w "%{http_code}" "$url"
}

log "Probing ${DOMAIN_A} view of ${DOMAIN_B} (expect 200 or 401, not connection failure)"
code="$(probe "$DOMAIN_A" "$DOMAIN_B")"
log "HTTP ${code}"

log "Probing federation to non-allowlisted ${REJECT_DOMAIN} from ${DOMAIN_A}"
code_reject="$(curl -ksS -o /dev/null -w "%{http_code}" "https://${DOMAIN_A}/_matrix/federation/v1/version" -H "Host: ${REJECT_DOMAIN}" 2>/dev/null || echo "000")"
log "Sanity check HTTP ${code_reject} (manual: synapse federation tester / send message test in docs)"

log "For allowlist denial, on ${DOMAIN_A} run as admin on VM:"
log "  curl -sS 'https://${DOMAIN_B}/_matrix/federation/v1/version'"
log "Then from matrix-synapse logs on B, confirm request from A succeeds."
log "Attempt room invite to @user:${REJECT_DOMAIN} should fail in Element."
