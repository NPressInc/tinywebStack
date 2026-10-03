#!/usr/bin/env bash
# Provision Synapse admin access token for dashboard member management (optional).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/lib/matrix-server.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/matrix-server.sh"

SYNAPSE_ADMIN_PASSWORD_FILE="${SYNAPSE_ADMIN_PASSWORD_FILE:-/etc/tinywebstack/secrets/synapse-admin.password}"

ensure_synapse_admin_password_dir() {
  local d
  d="$(dirname "$SYNAPSE_ADMIN_PASSWORD_FILE")"
  if [[ "$(id -u)" -eq 0 ]]; then
    install -d -m 700 -o root -g root "$d"
  else
    mkdir -p "$d"
    chmod 700 "$d"
  fi
}

read_or_create_synapse_admin_password() {
  local pw old_umask tmp
  if [[ -s "$SYNAPSE_ADMIN_PASSWORD_FILE" ]]; then
    pw="$(<"$SYNAPSE_ADMIN_PASSWORD_FILE")"
    printf '%s' "$pw"
    return 0
  fi
  pw="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
  ensure_synapse_admin_password_dir
  old_umask="$(umask)"
  umask 077
  tmp="$(mktemp "${SYNAPSE_ADMIN_PASSWORD_FILE}.tmp.XXXXXX")"
  printf '%s' "$pw" >"$tmp"
  if [[ "$(id -u)" -eq 0 ]]; then
    install -m 600 -o root -g root "$tmp" "$SYNAPSE_ADMIN_PASSWORD_FILE"
  else
    install -m 600 "$tmp" "$SYNAPSE_ADMIN_PASSWORD_FILE"
  fi
  rm -f "$tmp"
  umask "$old_umask"
  printf '%s' "$pw"
}

synapse_login_http_code() {
  local url=$1 body=$2 tmp=$3 code
  local extra=("${@:4}")
  code="$(curl -sSL -o "$tmp" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d "$body" \
    "${extra[@]}" \
    "$url" 2>/dev/null || true)"
  code="${code//$'\n'/}"
  code="${code//$'\r'/}"
  printf '%s' "$code"
}

write_synapse_admin_token_file() {
  local token_file=$1 token=$2
  local tok_dir old_umask tmp
  tok_dir="$(dirname "$token_file")"
  mkdir -p "$tok_dir"
  old_umask="$(umask)"
  umask 077
  tmp="$(mktemp "${tok_dir}/.synapse-admin-token.tmp.XXXXXX")"
  printf '%s\n' "$token" >"$tmp"
  if [[ "$(id -u)" -eq 0 ]]; then
    install -m 600 -o root -g www-data "$tmp" "$token_file"
  else
    install -m 600 "$tmp" "$token_file"
  fi
  rm -f "$tmp"
  umask "$old_umask"
}

provision_synapse_admin_token() {
  local main_domain=${1:-}
  local token_file=${2:-/etc/tinywebstack/synapse-admin-token}
  local admin_local=${TWS_SYNAPSE_ADMIN_USER:-tws-fam-admin}

  if [[ -s "$token_file" ]]; then
    log "Synapse admin token already present at ${token_file}"
    return 0
  fi

  require_cmd curl python3 openssl

  local hs_yaml=""
  if [[ -n "${TWS_SYNAPSE_HOMESERVER_YAML:-}" && -f "${TWS_SYNAPSE_HOMESERVER_YAML}" ]]; then
    hs_yaml="${TWS_SYNAPSE_HOMESERVER_YAML}"
  else
    for c in /etc/matrix-synapse/homeserver.yaml /etc/synapse/homeserver.yaml; do
      [[ -f "$c" ]] && hs_yaml=$c && break
    done
  fi
  [[ -n "$hs_yaml" ]] || {
    log "No homeserver.yaml found; skipping admin token provisioning"
    return 0
  }

  local register_bin=""
  if [[ -n "${TWS_SYNAPSE_REGISTER_BIN:-}" && -x "${TWS_SYNAPSE_REGISTER_BIN}" ]]; then
    register_bin="${TWS_SYNAPSE_REGISTER_BIN}"
  else
    for c in \
      /var/www/synapse/venv/bin/register_new_matrix_user \
      /opt/yunohost/matrix-synapse/venv/bin/register_new_matrix_user \
      /usr/bin/register_new_matrix_user; do
      [[ -x "$c" ]] && register_bin=$c && break
    done
  fi

  local server_name
  server_name="$(python3 -c "import yaml; print(yaml.safe_load(open('${hs_yaml}'))['server_name'])")"
  [[ -n "$main_domain" ]] || main_domain=$server_name

  local admin_pass
  admin_pass="$(read_or_create_synapse_admin_password)"
  local mxid="@${admin_local}:${server_name}"

  if [[ -n "$register_bin" ]]; then
    if ! printf '%s\n%s\n' "$admin_pass" "$admin_pass" | "$register_bin" -c "$hs_yaml" -u "$admin_local" -a 2>/dev/null; then
      log "Admin user ${admin_local} may already exist; attempting login only"
    fi
  else
    log "register_new_matrix_user not found; skipping admin user creation"
    return 0
  fi

  local matrix_client_base matrix_https_host matrix_ca
  matrix_client_base="$(matrix_client_base_url "$main_domain")"
  matrix_https_host="$(
    python3 -c 'import sys; from urllib.parse import urlparse; print(urlparse(sys.argv[1]).hostname or "")' \
      "$matrix_client_base"
  )"
  matrix_ca="/etc/yunohost/certs/${matrix_https_host}/ca.pem"
  if [[ ! -f "$matrix_ca" ]]; then
    matrix_ca="/etc/yunohost/certs/${main_domain}/ca.pem"
  fi
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
  tok_http="$(synapse_login_http_code \
    "http://127.0.0.1:8008/_matrix/client/v3/login" "$login_body" "$tmp")"
  if [[ "$tok_http" != "200" ]]; then
    tok_http="$(synapse_login_http_code \
      "${matrix_client_base}/_matrix/client/v3/login" "$login_body" "$tmp" \
      --cacert "$matrix_ca")"
  fi
  if [[ "$tok_http" != "200" ]]; then
    tok_http="$(synapse_login_http_code \
      "${matrix_client_base}/_matrix/client/v3/login" "$login_body" "$tmp" -k)"
  fi
  if [[ "$tok_http" != "200" ]]; then
    rm -f "$tmp"
    log "WARN: could not log in Synapse admin user (HTTP ${tok_http})"
    return 0
  fi
  local access_token
  access_token="$(python3 - <<PY
import json
from pathlib import Path
data = json.loads(Path("$tmp").read_text())
Path("$tmp").unlink(missing_ok=True)
token = data.get("access_token", "")
if not token:
    raise SystemExit("no access_token")
print(token)
PY
)"
  write_synapse_admin_token_file "$token_file" "$access_token"
  log "Provisioned Synapse admin token for ${mxid} at ${token_file}"
}
