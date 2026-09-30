#!/usr/bin/env bash
# Create shared family calendars and write /etc/tinywebstack/calendar-state.json (idempotent).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${TW_STACK_ROOT}/lib/secrets.sh"
# shellcheck source=scripts/lib/nextcloud-occ.sh
source "${TW_STACK_ROOT}/lib/nextcloud-occ.sh"
load_config

usage() {
  echo "Usage: setup-family-calendars.sh MAIN_DOMAIN NODE_NAME"
  exit 1
}

[[ $# -eq 2 ]] || usage
MAIN_DOMAIN=$1
NODE_NAME=$2

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

PARENT_USER="${TWS_PARENT_USER:-parent}"
KID_USER="${TWS_KID_USER:-kid}"
CALENDAR_USERS="${TWS_CALENDAR_USERS:-${PARENT_USER},${KID_USER},alice,bob}"
PARENT_PASSWORD="$(user_test_password "$NODE_NAME" "$PARENT_USER" PARENT_PASSWORD)"
[[ -n "$PARENT_PASSWORD" ]] || die "${PARENT_USER^^}_PASSWORD required (spark secrets / remote.env)"

OCC="$(nextcloud_occ_path)" || die "Nextcloud occ not found (install nextcloud first)"
OCC_USER="$(nextcloud_occ_user "$OCC")"
NC_PATH="${TWS_NEXTCLOUD_PATH:-/nextcloud}"

MODULE="${TW_STACK_ROOT}/family/calendar_module"
VENV="/opt/tinywebstack-calendar-venv"
if [[ ! -x "${VENV}/bin/pip" ]]; then
  python3 -m venv "$VENV"
fi
"${VENV}/bin/pip" install -q --upgrade pip
"${VENV}/bin/pip" install -q -e "$MODULE"

FAMILY_GROUP="$(python3 -c "
import sys
sys.path.insert(0, '${MODULE}')
from tinywebstack_calendar.naming import family_group_name
print(family_group_name('${MAIN_DOMAIN}', '${NODE_NAME}'))
")"

if ! yunohost user group list --output-as json | python3 -c "import json,sys; g=sys.argv[1]; d=json.load(sys.stdin); groups=d.get('groups',d); sys.exit(0 if g in groups else 1)" "$FAMILY_GROUP"; then
  yunohost user group create "$FAMILY_GROUP"
fi
for member in "$PARENT_USER" "$KID_USER"; do
  yunohost user group add "$FAMILY_GROUP" "$member" 2>/dev/null || true
done

CAFILE=""
if [[ -f /etc/tinywebstack/lab-ca.pem ]]; then
  CAFILE="/etc/tinywebstack/lab-ca.pem"
elif [[ -f "${TW_STACK_ROOT}/lab-certs/lab-ca.crt.pem" ]]; then
  CAFILE="${TW_STACK_ROOT}/lab-certs/lab-ca.crt.pem"
fi

CA_ARG=()
[[ -n "$CAFILE" ]] && CA_ARG=(--cafile "$CAFILE")

run_nextcloud_occ ldap:check-group "$FAMILY_GROUP" --update 2>/dev/null || true

export TWS_CALENDAR_SETUP_OWNER_PASSWORD="$PARENT_PASSWORD"

"${VENV}/bin/python" -m tinywebstack_calendar.setup \
  "$MAIN_DOMAIN" "$NODE_NAME" \
  --occ-path "$OCC" \
  --occ-user "$OCC_USER" \
  --owner "$PARENT_USER" \
  --nextcloud-path "$NC_PATH" \
  --federation-test-group "${TWS_FEDERATION_TEST_GROUP:-federation-test}" \
  --users "$CALENDAR_USERS" \
  "${CA_ARG[@]}"

log "Family calendars configured (${FAMILY_GROUP}, owner ${PARENT_USER})"
