#!/usr/bin/env bash
# Merge trusted_domains from family policy into Synapse federation allowlist.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

usage() {
  echo "Usage: family-sync-federation.sh MAIN_DOMAIN"
  exit 1
}

[[ $# -eq 1 ]] || usage
MAIN_DOMAIN=$1
POLICY="${TWS_POLICY_PATH:-/etc/tinywebstack/family-policy.json}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

[[ -f "$POLICY" ]] || die "Missing policy ${POLICY}"

mapfile -t PEERS < <(python3 - <<PY
import json
from pathlib import Path
data = json.loads(Path("${POLICY}").read_text())
for d in sorted(set(data.get("trusted_domains") or [])):
    if d and d != "${MAIN_DOMAIN}":
        print(d)
PY
)

if [[ ${#PEERS[@]} -eq 0 ]]; then
  log "No trusted_domains peers to add for ${MAIN_DOMAIN}"
  exit 0
fi

"${TW_STACK_ROOT}/vm/synapse-federation-allowlist.sh" "$MAIN_DOMAIN" "${PEERS[@]}"
if [[ -x "${TW_STACK_ROOT}/vm/mobilizon-federation-sync.sh" ]]; then
  "${TW_STACK_ROOT}/vm/mobilizon-federation-sync.sh" "$MAIN_DOMAIN" || log "WARN: Mobilizon federation sync failed"
fi
log "Federation synced for ${MAIN_DOMAIN}: ${PEERS[*]}"
