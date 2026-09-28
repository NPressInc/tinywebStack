#!/usr/bin/env bash
# Provision Synapse admin access token for dashboard member management (optional).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/lib/matrix-server.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/matrix-server.sh"

provision_synapse_admin_token() {
  local main_domain=${1:-}
  local token_file=${2:-/etc/tinywebstack/synapse-admin-token}
  local admin_local=${TWS_SYNAPSE_ADMIN_USER:-tws-fam-admin}

  if [[ -s "$token_file" ]]; then
    log "Synapse admin token already present at ${token_file}"
    return 0
  fi

  require_cmd curl python3

  local hs_yaml=""
  for c in /etc/matrix-synapse/homeserver.yaml /etc/synapse/homeserver.yaml; do
    [[ -f "$c" ]] && hs_yaml=$c && break
  done
  [[ -n "$hs_yaml" ]] || {
    log "No homeserver.yaml found; skipping admin token provisioning"
    return 0
  }

  local register_bin=""
  for c in \
    /var/www/synapse/venv/bin/register_new_matrix_user \
    /opt/yunohost/matrix-synapse/venv/bin/register_new_matrix_user \
    /usr/bin/register_new_matrix_user; do
    [[ -x "$c" ]] && register_bin=$c && break
  done

  local server_name
  server_name="$(python3 -c "import yaml; print(yaml.safe_load(open('${hs_yaml}'))['server_name'])")"
  [[ -n "$main_domain" ]] || main_domain=$server_name

  local admin_pass
  admin_pass="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
  local mxid="@${admin_local}:${server_name}"

  if [[ -n "$register_bin" ]]; then
    if ! "$register_bin" -c "$hs_yaml" -u "$admin_local" -p "$admin_pass" -a 2>/dev/null; then
      log "Admin user ${admin_local} may already exist; attempting login only"
    fi
  else
    log "register_new_matrix_user not found; skipping admin user creation"
    return 0
  fi

  local matrix_host
  matrix_host="$(matrix_public_host "$main_domain")"
  local login_body
  login_body="$(python3 - <<PY
import json
print(json.dumps({
    "type": "m.login.password",
    "identifier": {"type": "m.id.user", "user": "${admin_local}"},
    "password": "${admin_pass}",
}))
PY
)"

  local tmp tok_http
  tmp="$(mktemp)"
  tok_http="$(curl -fsSL -o "$tmp" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d "$login_body" \
    "https://${matrix_host}/_matrix/client/v3/login" \
    --cacert "/etc/yunohost/certs/${main_domain}/ca.pem" 2>/dev/null || echo 000)"
  if [[ "$tok_http" != "200" ]]; then
    tok_http="$(curl -fsSLk -o "$tmp" -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' \
      -d "$login_body" \
      "https://${matrix_host}/_matrix/client/v3/login" || echo 000)"
  fi
  if [[ "$tok_http" != "200" ]]; then
    rm -f "$tmp"
    log "WARN: could not log in Synapse admin user (HTTP ${tok_http})"
    return 0
  fi
  python3 - <<PY
import json
from pathlib import Path
data = json.loads(Path("$tmp").read_text())
Path("$tmp").unlink(missing_ok=True)
token = data.get("access_token", "")
if not token:
    raise SystemExit("no access_token")
Path("${token_file}").write_text(token + "\n")
PY
  chown root:www-data "$token_file"
  chmod 600 "$token_file"
  log "Provisioned Synapse admin token for ${mxid} at ${token_file}"
}
