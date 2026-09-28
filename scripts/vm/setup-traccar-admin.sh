#!/usr/bin/env bash
# Create Traccar first admin via API (idempotent). Traccar 6.16+ rejects administrator:true on empty DB.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
load_config

usage() {
  echo "Usage: setup-traccar-admin.sh MAIN_DOMAIN NODE_NAME"
  exit 1
}

[[ $# -eq 2 ]] || usage
MAIN_DOMAIN=$1
# shellcheck disable=SC2034
NODE_NAME=$2

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if ! yunohost app list 2>/dev/null | grep -qw traccar; then
  log "Traccar not installed; skipping admin setup"
  exit 0
fi

LOC_D="$(location_domain "$MAIN_DOMAIN")"
BASE="https://${LOC_D}"
PASS="${TRACCAR_ADMIN_PASSWORD:-}"
[[ -n "$PASS" ]] || die "TRACCAR_ADMIN_PASSWORD must be set (spark secrets)"
EMAIL="${TRACCAR_ADMIN_LOGIN:-admin@${MAIN_DOMAIN}}"

require_cmd curl python3

USERS_JSON="$(mktemp)"
USERS_CODE="$(curl -ksS -o "$USERS_JSON" -w '%{http_code}' "${BASE}/api/users" || true)"

admin_exists=0
if [[ "$USERS_CODE" == "200" ]]; then
  admin_exists="$(python3 - <<PY
import json
with open("$USERS_JSON") as f:
    data=json.load(f)
print(1 if isinstance(data, list) and len(data) > 0 else 0)
PY
)"
elif [[ "$USERS_CODE" == "401" || "$USERS_CODE" == "403" ]]; then
  admin_exists=1
fi
rm -f "$USERS_JSON"

if [[ "$admin_exists" == "1" ]]; then
  log "Traccar admin already exists on ${LOC_D}"
else
  HTTP_CODE="$(curl -ksS -o /tmp/traccar-user.json -w '%{http_code}' -X POST "${BASE}/api/users" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"Admin\",\"email\":\"${EMAIL}\",\"password\":\"${PASS}\"}")"
  if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
    die "Traccar admin create failed HTTP ${HTTP_CODE}: $(cat /tmp/traccar-user.json 2>/dev/null)"
  fi
  log "Created Traccar admin ${EMAIL} on ${LOC_D} (first user is administrator)"
fi
