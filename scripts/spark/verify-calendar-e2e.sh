#!/usr/bin/env bash
# Verify Nextcloud Calendar install, SSO/CalDAV login, shared calendars, invite round trip.
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/tw_stack_root.sh
source "${_script_dir}/../lib/tw_stack_root.sh"
TW_STACK_ROOT="$(tw_stack_root_from_script_dir "$_script_dir")" || {
  echo "[tinywebstack] ERROR: Cannot locate tinywebStack root from ${_script_dir}" >&2
  exit 1
}
if [[ -f "${TW_STACK_ROOT}/scripts/lib/common.sh" ]]; then
  # shellcheck source=scripts/lib/common.sh
  source "${TW_STACK_ROOT}/scripts/lib/common.sh"
  # shellcheck source=scripts/lib/domains.sh
  source "${TW_STACK_ROOT}/scripts/lib/domains.sh"
  # shellcheck source=scripts/lib/secrets.sh
  source "${TW_STACK_ROOT}/scripts/lib/secrets.sh"
else
  # shellcheck source=scripts/lib/common.sh
  source "${TW_STACK_ROOT}/lib/common.sh"
  # shellcheck source=scripts/lib/domains.sh
  source "${TW_STACK_ROOT}/lib/domains.sh"
  # shellcheck source=scripts/lib/secrets.sh
  source "${TW_STACK_ROOT}/lib/secrets.sh"
fi
load_config
load_secrets

usage() {
  cat <<'EOF'
Usage: verify-calendar-e2e.sh NODE_NAME MAIN_DOMAIN [PARENT_USER] [KID_USER]

Participant usernames default to $TWS_PARENT_USER / $TWS_KID_USER (parent/kid).
Their passwords resolve in order: $<USERNAME>_PASSWORD env, then spark secrets
(<USERNAME>_PASSWORD_<NODE>). Without a lab CA (or TWS_CA_BUNDLE), TLS
verification uses the system trust store; set TWS_REQUIRE_LAB_CA=1 to keep the
old hard-fail.
Requires calendar-state.json on the node (run setup-family-calendars.sh via family-init).
EOF
  exit 1
}

[[ $# -ge 2 && $# -le 4 ]] || usage
NODE_NAME=$1
MAIN_DOMAIN=$2
PARENT_USER=${3:-${TWS_PARENT_USER:-parent}}
KID_USER=${4:-${TWS_KID_USER:-kid}}

require_cmd python3

validate_test_user_name "$PARENT_USER" parent-user
validate_test_user_name "$KID_USER" kid-user
PARENT_PASSWORD="$(user_test_password "$NODE_NAME" "$PARENT_USER" PARENT_PASSWORD)"
KID_PASSWORD="$(user_test_password "$NODE_NAME" "$KID_USER" KID_PASSWORD)"
[[ -n "$PARENT_PASSWORD" && -n "$KID_PASSWORD" ]] || \
  die "Set passwords for ${PARENT_USER}/${KID_USER} (env ${PARENT_USER^^}_PASSWORD / ${KID_USER^^}_PASSWORD or $(secrets_file))"

LAB_CA="$(resolve_ca_bundle || true)"
require_ca_bundle_or_die "$LAB_CA"
[[ -n "$LAB_CA" ]] || log "No lab CA found — verifying TLS against the system trust store"
NC_PATH="${TWS_NEXTCLOUD_PATH:-/nextcloud}"
CALDAV_ROOT="https://$(nextcloud_domain "$MAIN_DOMAIN")${NC_PATH}/remote.php/dav"
ATTENDEE_EMAIL="${KID_USER}@${MAIN_DOMAIN}"
ORGANIZER_EMAIL="${PARENT_USER}@${MAIN_DOMAIN}"

MODULE="${TW_STACK_ROOT}/family/calendar_module"
VENV="${TW_STACK_ROOT}/.tools/calendar-verify-venv"
if [[ ! -x "${VENV}/bin/pip" ]]; then
  python3 -m venv "$VENV"
  "${VENV}/bin/pip" install -q --upgrade pip
fi
"${VENV}/bin/pip" install -q -e "${MODULE}[verify]"

CA_ARGS=()
[[ -n "$LAB_CA" ]] && CA_ARGS=(--cafile "$LAB_CA")

export TWS_CALENDAR_VERIFY_PASSWORD="$PARENT_PASSWORD"
"${VENV}/bin/python" -m tinywebstack_calendar.verify login \
  --caldav-root "$CALDAV_ROOT" \
  --user "$PARENT_USER" \
  "${CA_ARGS[@]}"

export TWS_CALENDAR_VERIFY_PASSWORD="$KID_PASSWORD"
"${VENV}/bin/python" -m tinywebstack_calendar.verify login \
  --caldav-root "$CALDAV_ROOT" \
  --user "$KID_USER" \
  "${CA_ARGS[@]}"

export TWS_CALENDAR_VERIFY_PARENT_PASSWORD="$PARENT_PASSWORD"
export TWS_CALENDAR_VERIFY_KID_PASSWORD="$KID_PASSWORD"
export TWS_CALENDAR_VERIFY_ORGANIZER_EMAIL="$ORGANIZER_EMAIL"
"${VENV}/bin/python" -m tinywebstack_calendar.verify invite-roundtrip \
  --caldav-root "$CALDAV_ROOT" \
  --owner-user "$PARENT_USER" \
  --attendee-user "$KID_USER" \
  --attendee-email "$ATTENDEE_EMAIL" \
  --organizer-email "$ORGANIZER_EMAIL" \
  "${CA_ARGS[@]}"

log "Calendar e2e OK for ${NODE_NAME} (${MAIN_DOMAIN})"
