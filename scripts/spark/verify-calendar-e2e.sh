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
Usage: verify-calendar-e2e.sh NODE_NAME MAIN_DOMAIN

Reads PARENT_PASSWORD / KID_PASSWORD from spark secrets (LAB_PASSWORD in lab).
Requires calendar-state.json on the node (run setup-family-calendars.sh via family-init).
EOF
  exit 1
}

[[ $# -eq 2 ]] || usage
NODE_NAME=$1
MAIN_DOMAIN=$2

require_cmd python3

PARENT_PASSWORD="${PARENT_PASSWORD:-$(read_node_secret "$NODE_NAME" parent_password || true)}"
KID_PASSWORD="${KID_PASSWORD:-$(read_node_secret "$NODE_NAME" kid_password || true)}"
[[ -n "$PARENT_PASSWORD" && -n "$KID_PASSWORD" ]] || \
  die "Set parent/kid passwords in $(secrets_file)"

resolve_lab_ca() {
  local c
  for c in \
    "${TW_STACK_LAB_CA_DIR:-}/lab-ca.crt.pem" \
    "${TW_STACK_ROOT}/lab-certs/lab-ca.crt.pem" \
    "${TW_STACK_SECRETS_DIR:-}/lab-ca/lab-ca.crt.pem"
  do
    if [[ -f "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

LAB_CA="$(resolve_lab_ca || true)"
NC_PATH="${TWS_NEXTCLOUD_PATH:-/nextcloud}"
CALDAV_ROOT="https://$(nextcloud_domain "$MAIN_DOMAIN")${NC_PATH}/remote.php/dav"
ATTENDEE_EMAIL="kid@${MAIN_DOMAIN}"
ORGANIZER_EMAIL="parent@${MAIN_DOMAIN}"

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
  --user parent \
  "${CA_ARGS[@]}"

export TWS_CALENDAR_VERIFY_PASSWORD="$KID_PASSWORD"
"${VENV}/bin/python" -m tinywebstack_calendar.verify login \
  --caldav-root "$CALDAV_ROOT" \
  --user kid \
  "${CA_ARGS[@]}"

export TWS_CALENDAR_VERIFY_PARENT_PASSWORD="$PARENT_PASSWORD"
export TWS_CALENDAR_VERIFY_KID_PASSWORD="$KID_PASSWORD"
export TWS_CALENDAR_VERIFY_ORGANIZER_EMAIL="$ORGANIZER_EMAIL"
"${VENV}/bin/python" -m tinywebstack_calendar.verify invite-roundtrip \
  --caldav-root "$CALDAV_ROOT" \
  --attendee-email "$ATTENDEE_EMAIL" \
  --organizer-email "$ORGANIZER_EMAIL" \
  "${CA_ARGS[@]}"

log "Calendar e2e OK for ${NODE_NAME} (${MAIN_DOMAIN})"
