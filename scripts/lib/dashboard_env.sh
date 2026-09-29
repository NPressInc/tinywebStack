#!/usr/bin/env bash
# Safe read of /etc/tinywebstack/dashboard.env (never bash-source; unquoted spaces break parsing).
# shellcheck disable=SC2034

load_dashboard_env_selective() {
  local f="${1:-/etc/tinywebstack/dashboard.env}"
  [[ -f "$f" ]] || return 0
  local mod="${TW_STACK_ROOT}/family/synapse_module"
  [[ -d "$mod" ]] || return 0
  # shellcheck disable=SC1091
  eval "$(
    PYTHONPATH="${mod}${PYTHONPATH:+:${PYTHONPATH}}" python3 - "$f" <<'PY'
import shlex
import sys
from tinywebstack_family.dashboard_env import parse_env_file

path = sys.argv[1]
keys = (
    "TWS_SERVER_NAME",
    "TWS_CA_BUNDLE",
    "TWS_LAB_TLS_INSECURE",
    "TWS_SYNAPSE_ADMIN_TOKEN_FILE",
    "TWS_OWNTRACKS_KIDS_FILE",
    "TWS_OWNTRACKS_HTPASSWD",
    "TWS_OWNTRACKS_PUBLISH_URL",
    "TWS_PARENTS_GROUP",
    "TWS_KIDS_GROUP",
)
data = parse_env_file(path)
for k in keys:
    if k in data:
        print(f"export {k}={shlex.quote(data[k])}")
PY
  )"
  if [[ -z "${TWS_CA_BUNDLE:-}" && -f /etc/tinywebstack/lab-ca.pem ]]; then
    TWS_CA_BUNDLE=/etc/tinywebstack/lab-ca.pem
  fi
}
