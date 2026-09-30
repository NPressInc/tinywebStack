#!/usr/bin/env bash
# Create shared family calendars and write /etc/tinywebstack/calendar-state.json (idempotent).
#
# Default list is the lab pair (parent + kid, plus lab alice/bob personal calendars) so the
# existing spark flow is unchanged. Override with --users "william,sophie,emma" or
# TWS_FAMILY_USERS="william,sophie,emma" to provision a real-named household.
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
# shellcheck source=scripts/lib/family_users.sh
source "${TW_STACK_ROOT}/lib/family_users.sh"
load_config

usage() {
  cat <<'EOF'
Usage: setup-family-calendars.sh MAIN_DOMAIN NODE_NAME [--users "u1,u2,..."]

Creates the family group and shared calendars (tws-family/tws-parents/tws-kids)
and personal calendars for each member. User list priority: --users flag >
TWS_FAMILY_USERS env > lab default (parent,kid — lab also provisions alice/bob
personal calendars). Shared calendars are owned by the first user (override
with TWS_FAMILY_OWNER); the owner password comes from <OWNER>_PASSWORD or the
<owner>_password node secret (lab parent_password secret still works).
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage
MAIN_DOMAIN=$1
NODE_NAME=$2
shift 2
EXTRA_ARGS=("$@")

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

# Single source of truth for the member list: scripts/lib/family_users.sh
# (--users flag > TWS_FAMILY_USERS env > lab default parent,kid).
FAMILY_USERS_CSV="$(resolve_family_users "${EXTRA_ARGS[@]}")"
OWNER="$(resolve_family_owner "$FAMILY_USERS_CSV")"

# Owner password via the scripts/lib/secrets.sh chain: <OWNER>_PASSWORD env
# (dot/hyphen in name → underscore), the legacy PARENT_PASSWORD extra key,
# then the <owner>_password node secret (lab's parent_password secret still
# resolves when owner=parent).
OWNER_PASSWORD_ENV_KEY="$(test_password_env_key "$OWNER")"
OWNER_PASSWORD="$(user_test_password "$NODE_NAME" "$OWNER" PARENT_PASSWORD)"
[[ -n "$OWNER_PASSWORD" ]] || die "Password for calendar owner '${OWNER}' required (set ${OWNER_PASSWORD_ENV_KEY} or a '${OWNER}_password' node secret)"

# Personal calendars: lab default keeps the matrix lab users (alice/bob, honoring
# TWS_ALICE_USER/TWS_BOB_USER) alongside parent/kid; custom households provision
# personal calendars for exactly their own members.
if [[ "$FAMILY_USERS_CSV" == "$TWS_FAMILY_USERS_DEFAULT" ]]; then
  CALENDAR_USERS="$(normalize_user_list "${FAMILY_USERS_CSV},${TWS_ALICE_USER:-alice},${TWS_BOB_USER:-bob}")"
else
  CALENDAR_USERS="$FAMILY_USERS_CSV"
fi

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
# Family group members come from the same resolved list (family_users.sh).
IFS=',' read -r -a _family_members <<< "$FAMILY_USERS_CSV"
for member in "${_family_members[@]}"; do
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

export TWS_CALENDAR_SETUP_OWNER_PASSWORD="$OWNER_PASSWORD"

"${VENV}/bin/python" -m tinywebstack_calendar.setup \
  "$MAIN_DOMAIN" "$NODE_NAME" \
  --occ-path "$OCC" \
  --occ-user "$OCC_USER" \
  --owner "$OWNER" \
  --nextcloud-path "$NC_PATH" \
  --federation-test-group "${TWS_FEDERATION_TEST_GROUP:-federation-test}" \
  --users "$CALENDAR_USERS" \
  "${CA_ARG[@]}"

log "Family calendars configured (${FAMILY_GROUP}, owner ${OWNER}, users ${FAMILY_USERS_CSV})"
