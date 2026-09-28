#!/usr/bin/env bash
# Sync Mobilizon ActivityPub relays with trusted_domains (allowlist-only federation).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${TW_STACK_ROOT}/lib/secrets.sh"
load_config

usage() {
  cat <<'EOF'
Usage: mobilizon-federation-sync.sh MAIN_DOMAIN [NODE_NAME]

Uses family-policy.json trusted_domains and Mobilizon admin GraphQL API.
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
MAIN_DOMAIN=$1
shift
NODE_NAME=""
EXTRA_PEERS=()
while [[ $# -gt 0 ]]; do
  if [[ -z "$NODE_NAME" && "$1" != *.* ]]; then
    NODE_NAME=$1
    shift
    continue
  fi
  EXTRA_PEERS+=("$1")
  shift
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

if ! yunohost app list 2>/dev/null | grep -qw mobilizon; then
  log "Mobilizon not installed — federation sync skipped"
  exit 0
fi

POLICY="${TWS_POLICY_PATH:-/etc/tinywebstack/family-policy.json}"
[[ -f "$POLICY" ]] || die "Missing policy ${POLICY}"

EVENTS_D="$(events_domain "$MAIN_DOMAIN")"
ADMIN_USER="${MOBILIZON_ADMIN_USER:-parent}"
ADMIN_EMAIL="${MOBILIZON_ADMIN_EMAIL:-${ADMIN_USER}@${MAIN_DOMAIN}}"
ADMIN_PASSWORD="${MOBILIZON_ADMIN_PASSWORD:-${PARENT_PASSWORD:-}}"
if [[ -z "$ADMIN_PASSWORD" && -n "$NODE_NAME" ]]; then
  ADMIN_PASSWORD="$(read_node_secret "$NODE_NAME" parent_password || true)"
fi
[[ -n "$ADMIN_PASSWORD" ]] || die "MOBILIZON_ADMIN_PASSWORD or parent_password secret required"

REJECT_PROBE="${MOBILIZON_REJECT_PROBE:-mobilizon.fr}"
EXTRA_PEERS_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${EXTRA_PEERS[@]}")"
export MAIN_DOMAIN EVENTS_D ADMIN_EMAIL ADMIN_PASSWORD POLICY REJECT_PROBE TW_STACK_ROOT EXTRA_PEERS_JSON

python3 - <<'PY'
import json
import os
import ssl
import sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.environ["TW_STACK_ROOT"], "family", "synapse_module"))
from tinywebstack_family.mobilizon import MobilizonClient, sync_instance_federation

main = os.environ["MAIN_DOMAIN"]
base = f"https://{os.environ['EVENTS_D']}"
policy = json.loads(Path(os.environ["POLICY"]).read_text(encoding="utf-8"))
trusted = [d for d in policy.get("trusted_domains") or [] if d and d != main]
extra = json.loads(os.environ.get("EXTRA_PEERS_JSON") or "[]")
for d in extra:
    if d and d != main and d not in trusted:
        trusted.append(d)

ctx = None
ca = Path("/etc/tinywebstack/lab-ca.pem")
if os.environ.get("TWS_LAB_TLS_INSECURE") == "1" or not ca.is_file():
    ctx = ssl._create_unverified_context()
else:
    ctx = ssl.create_default_context(cafile=str(ca))

client = MobilizonClient.login(
    base,
    os.environ["ADMIN_EMAIL"],
    os.environ["ADMIN_PASSWORD"],
    ssl_context=ctx,
)
result = sync_instance_federation(
    client,
    local_main_domain=main,
    trusted_main_domains=trusted,
    reject_probe_host=os.environ.get("REJECT_PROBE"),
    ssl_context=ctx,
)
print(json.dumps(result, indent=2))
PY

log "Mobilizon federation synced for ${MAIN_DOMAIN}"
