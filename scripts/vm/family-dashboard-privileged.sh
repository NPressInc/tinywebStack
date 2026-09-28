#!/usr/bin/env bash
# Narrow sudo helpers for the family dashboard (www-data). Root only.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

usage() {
  cat <<'EOF'
Usage:
  family-dashboard-privileged.sh user-create USER FULL_NAME ROLE MAIN_DOMAIN PASSWORD
  family-dashboard-privileged.sh user-delete USER
  family-dashboard-privileged.sh password-reset USER PASSWORD
  family-dashboard-privileged.sh synapse-user-status LOCALPART SERVER_NAME
  family-dashboard-privileged.sh owntracks-issue USER MAIN_DOMAIN LOCATION_DOMAIN

ROLE is parent or kid.
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
CMD=$1
shift

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

PARENTS_GROUP="${TWS_PARENTS_GROUP:-parents}"
KIDS_GROUP="${TWS_KIDS_GROUP:-kids}"
STORE="${TWS_OWNTRACKS_KIDS_FILE:-/etc/tinywebstack/owntracks-kids.json}"
SYNAPSE_TOKEN_FILE="${TWS_SYNAPSE_ADMIN_TOKEN_FILE:-/etc/tinywebstack/synapse-admin-token}"

valid_username() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{1,30}$ ]]
}

case "$CMD" in
  user-create)
    [[ $# -eq 5 ]] || usage
    USER=$1
    FULL=$2
    ROLE=$3
    DOMAIN=$4
    PASS=$5
    valid_username "$USER" || die "Invalid username: ${USER}"
    [[ "$ROLE" == parent || "$ROLE" == kid ]] || die "ROLE must be parent or kid"
    if yunohost user list 2>/dev/null | grep -qw "$USER"; then
      log "User ${USER} already exists"
    else
      yunohost user create "$USER" -F "$FULL" -p "$PASS" -d "$DOMAIN"
    fi
    G="$KIDS_GROUP"
    [[ "$ROLE" == parent ]] && G="$PARENTS_GROUP"
    yunohost user group adduser "$G" "$USER" 2>/dev/null || true
    "${TW_STACK_ROOT}/vm/family-groups.sh" >/dev/null 2>&1 || true
    printf 'OK user=%s role=%s\n' "$USER" "$ROLE"
    ;;

  user-delete)
    [[ $# -eq 1 ]] || usage
    USER=$1
    valid_username "$USER" || die "Invalid username"
    if yunohost user list 2>/dev/null | grep -qw "$USER"; then
      yunohost user delete "$USER"
    fi
    if [[ -f "$STORE" ]]; then
      python3 - <<PY
import json
from pathlib import Path
p = Path("${STORE}")
data = json.loads(p.read_text()) if p.is_file() else {}
data.pop("${USER}", None)
p.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
    fi
    printf 'OK deleted=%s\n' "$USER"
    ;;

  password-reset)
    [[ $# -eq 2 ]] || usage
    USER=$1
    PASS=$2
    valid_username "$USER" || die "Invalid username"
    yunohost user update "$USER" -p "$PASS"
    printf 'OK password-reset=%s\n' "$USER"
    ;;

  synapse-user-status)
    [[ $# -eq 2 ]] || usage
    LOCAL=$1
    SERVER=$2
    MXID="@${LOCAL}:${SERVER}"
    if [[ ! -f "$SYNAPSE_TOKEN_FILE" ]]; then
      printf 'status=unknown detail=no_admin_token mxid=%s\n' "$MXID"
      exit 0
    fi
    TOKEN="$(tr -d '\n' < "$SYNAPSE_TOKEN_FILE")"
    MATRIX_HOST="${TWS_MATRIX_SERVER:-matrix.${SERVER}}"
    ENC="$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("${MXID}", safe=""))
PY
)"
    URL="https://${MATRIX_HOST}/_synapse/admin/v2/users/${ENC}"
    TMP="$(mktemp)"
    CURL_OPTS=(-fsS)
    [[ "${TWS_LAB_TLS_INSECURE:-0}" == "1" ]] && CURL_OPTS+=(-k)
    if ! curl "${CURL_OPTS[@]}" -H "Authorization: Bearer ${TOKEN}" "$URL" -o "$TMP" 2>/dev/null; then
      rm -f "$TMP"
      printf 'status=not_found mxid=%s\n' "$MXID"
      exit 0
    fi
    python3 - <<PY
import json
from pathlib import Path
data = json.loads(Path("$TMP").read_text())
Path("$TMP").unlink(missing_ok=True)
name = data.get("name", "${MXID}")
deactivated = data.get("deactivated", False)
guest = data.get("is_guest", False)
print(f"status={'deactivated' if deactivated else 'active'} guest={guest} mxid={name}")
PY
    ;;

  owntracks-issue)
    [[ $# -eq 3 ]] || usage
    USER=$1
    _MAIN=$2
    LOC=$3
    valid_username "$USER" || die "Invalid username"
    DEV_ID="${USER}-phone"
    PASS="$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
    PUB_URL="${TWS_OWNTRACKS_PUBLISH_URL:-https://${LOC}/api/}"
    mkdir -p "$(dirname "$STORE")"
    python3 - <<PY
import json, secrets
from pathlib import Path
p = Path("${STORE}")
data = json.loads(p.read_text()) if p.is_file() else {}
data["${USER}"] = {
    "device_id": "${DEV_ID}",
    "username": "${USER}",
    "password": "${PASS}",
    "publish_url": "${PUB_URL}",
    "tracker_id": "${USER}"[:2] or "k1",
}
p.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
if p.stat().st_mode & 0o777 != 0o640:
    p.chmod(0o640)
PY
    chown root:www-data "$STORE" 2>/dev/null || chmod 640 "$STORE"
    printf 'OK user=%s device=%s password=%s url=%s tid=%s\n' "$USER" "$DEV_ID" "$PASS" "$PUB_URL" "${USER:0:2}"
    ;;

  *)
    usage
    ;;
esac
