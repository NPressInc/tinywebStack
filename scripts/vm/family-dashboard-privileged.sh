#!/usr/bin/env bash
# Narrow sudo helpers for the family dashboard (www-data). Root only.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/matrix-server.sh
source "${TW_STACK_ROOT}/lib/matrix-server.sh"
load_config

usage() {
  cat <<'EOF'
Usage:
  family-dashboard-privileged.sh user-create USER FULL_NAME ROLE MAIN_DOMAIN   # password on stdin
  family-dashboard-privileged.sh user-delete USER
  family-dashboard-privileged.sh password-reset USER   # password on stdin
  family-dashboard-privileged.sh list-users
  family-dashboard-privileged.sh synapse-user-status LOCALPART SERVER_NAME
  family-dashboard-privileged.sh owntracks-issue USER MAIN_DOMAIN LOCATION_DOMAIN
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
HTPASSWD="${TWS_OWNTRACKS_HTPASSWD:-/etc/tinywebstack/owntracks-recorder.htpasswd}"
SYNAPSE_TOKEN_FILE="${TWS_SYNAPSE_ADMIN_TOKEN_FILE:-/etc/tinywebstack/synapse-admin-token}"

read_secret() {
  local secret
  IFS= read -r secret || die "Expected secret on stdin"
  [[ -n "$secret" ]] || die "Empty secret on stdin"
  printf '%s' "$secret"
}

valid_username() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{1,30}$ ]]
}

user_exists() {
  yunohost user list --output-as json | python3 -c "import json,sys; u=sys.argv[1]; d=json.load(sys.stdin); users=d.get('users',d); sys.exit(0 if u in users else 1)" "$1"
}

yunohost_group_add() {
  yunohost user group add "$1" "$2"
}

init_owntracks_store() {
  if [[ ! -s "$STORE" ]]; then
    printf '{}\n' >"$STORE"
    chown root:www-data "$STORE"
    chmod 640 "$STORE"
  fi
}

case "$CMD" in
  list-users)
    yunohost user list --fields username,groups --output-as json
    ;;

  user-create)
    [[ $# -eq 4 ]] || usage
    USER=$1
    FULL=$2
    ROLE=$3
    DOMAIN=$4
    PASS="$(read_secret)"
    valid_username "$USER" || die "Invalid username: ${USER}"
    [[ "$ROLE" == parent || "$ROLE" == kid ]] || die "ROLE must be parent or kid"
    if user_exists "$USER"; then
      log "User ${USER} already exists"
    else
      yunohost user create "$USER" -F "$FULL" -p "$PASS" -d "$DOMAIN"
    fi
    G="$KIDS_GROUP"
    [[ "$ROLE" == parent ]] && G="$PARENTS_GROUP"
    yunohost_group_add "$G" "$USER"
    "${TW_STACK_ROOT}/vm/family-groups.sh"
    printf 'OK user=%s role=%s\n' "$USER" "$ROLE"
    ;;

  user-delete)
    [[ $# -eq 1 ]] || usage
    USER=$1
    valid_username "$USER" || die "Invalid username"
    if user_exists "$USER"; then
      yunohost user delete "$USER"
    fi
    init_owntracks_store
    python3 - <<PY
import json
from pathlib import Path
p = Path("${STORE}")
data = json.loads(p.read_text() or "{}")
data.pop("${USER}", None)
p.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
    if [[ -f "$HTPASSWD" ]]; then
      htpasswd -D "$HTPASSWD" "$USER" 2>/dev/null || true
    fi
    printf 'OK deleted=%s\n' "$USER"
    ;;

  password-reset)
    [[ $# -eq 1 ]] || usage
    USER=$1
    PASS="$(read_secret)"
    valid_username "$USER" || die "Invalid username"
    yunohost user update "$USER" -p "$PASS"
    if [[ -f "$HTPASSWD" ]] && grep -q "^${USER}:" "$HTPASSWD" 2>/dev/null; then
      htpasswd -b "$HTPASSWD" "$USER" "$PASS"
    fi
    printf 'OK password-reset=%s\n' "$USER"
    ;;

  synapse-user-status)
    [[ $# -eq 2 ]] || usage
    LOCAL=$1
    SERVER=$2
    MXID="@${LOCAL}:${SERVER}"
    if [[ ! -s "$SYNAPSE_TOKEN_FILE" ]]; then
      printf 'status=unknown detail=no_admin_token mxid=%s\n' "$MXID"
      exit 0
    fi
    TOKEN="$(tr -d '\n' < "$SYNAPSE_TOKEN_FILE")"
    [[ -n "$TOKEN" ]] || {
      printf 'status=unknown detail=no_admin_token mxid=%s\n' "$MXID"
      exit 0
    }
    HOST="$(matrix_public_host "$SERVER")"
    ENC="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$MXID")"
    URL="https://${HOST}/_synapse/admin/v2/users/${ENC}"
    TMP="$(mktemp)"
    CURL_OPTS=(-fsSL)
    CA="${TWS_CA_BUNDLE:-}"
    [[ -n "$CA" && -f "$CA" ]] && CURL_OPTS+=(--cacert "$CA")
    [[ "${TWS_LAB_TLS_INSECURE:-0}" == "1" ]] && CURL_OPTS+=(-k)
    HTTP="$(curl "${CURL_OPTS[@]}" -o "$TMP" -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}" "$URL" || true)"
    if [[ "$HTTP" != "200" ]]; then
      rm -f "$TMP"
      printf 'status=not_found http=%s mxid=%s\n' "$HTTP" "$MXID"
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
    require_cmd htpasswd openssl
    DEV_ID="${USER}-phone"
    PASS="$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
    PUB_URL="${TWS_OWNTRACKS_PUBLISH_URL:-https://${LOC}/recorder/pub}"
    mkdir -p "$(dirname "$STORE")"
    touch "$HTPASSWD"
    chown root:www-data "$HTPASSWD"
    chmod 640 "$HTPASSWD"
    htpasswd -b "$HTPASSWD" "$USER" "$PASS"
    init_owntracks_store
    python3 - <<PY
import json
from pathlib import Path
p = Path("${STORE}")
data = json.loads(p.read_text() or "{}")
data["${USER}"] = {
    "device_id": "${DEV_ID}",
    "username": "${USER}",
    "password": "${PASS}",
    "publish_url": "${PUB_URL}",
    "tracker_id": ("${USER}"[:2] or "k1"),
}
p.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
p.chmod(0o640)
PY
    chown root:www-data "$STORE"
    printf 'OK user=%s device=%s password=%s url=%s tid=%s\n' "$USER" "$DEV_ID" "$PASS" "$PUB_URL" "${USER:0:2}"
    ;;

  *)
    usage
    ;;
esac
