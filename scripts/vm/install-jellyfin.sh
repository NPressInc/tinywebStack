#!/usr/bin/env bash
# Optional Jellyfin from the official YunoHost app. No-op unless TWS_JELLYFIN=1.
# Does not create libraries, import media, or call the Jellyfin admin API.
# After setup, a saved tunnel handoff is updated (claim token, not the setup
# code) so jellyfin.<family> is added or removed, then cloudflared-apply.sh runs.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
# shellcheck source=scripts/lib/portal_tiles.sh
source "${TW_STACK_ROOT}/lib/portal_tiles.sh"

# The environment wins. Otherwise the one TWS_JELLYFIN line in tinyweb.env is
# the box setting. An unset variable must not look like "turn Jellyfin off":
# family-init defaults it to 0, and that must not delete a host.
JELLYFIN_EXPLICIT=0
if [[ -n "${TWS_JELLYFIN+x}" ]]; then
  JELLYFIN_EXPLICIT=1
else
  _jellyfin_env_file="${TWS_ETC_DIR:-/etc/tinywebstack}/tinyweb.env"
  if [[ -f "$_jellyfin_env_file" ]]; then
    while IFS= read -r _line || [[ -n "${_line-}" ]]; do
      _line="${_line%%#*}"
      _line="${_line#"${_line%%[![:space:]]*}"}"
      case "$_line" in
        TWS_JELLYFIN=*)
          TWS_JELLYFIN="${_line#TWS_JELLYFIN=}"
          export TWS_JELLYFIN
          JELLYFIN_EXPLICIT=1
          ;;
      esac
    done <"$_jellyfin_env_file"
  fi
  unset _jellyfin_env_file _line
fi
load_config

usage() {
  echo "Usage: install-jellyfin.sh MAIN_DOMAIN"
  exit 1
}

[[ $# -ge 1 ]] || usage
MAIN_DOMAIN=$1

handoff_ready() {
  [[ -f "${TWS_ETC_DIR:-/etc/tinywebstack}/cloudflared/handoff.json" ]]
}

handoff_has_jellyfin() {
  local file="${TWS_ETC_DIR:-/etc/tinywebstack}/cloudflared/handoff.json"
  [[ -f "$file" ]] || return 1
  python3 - "$file" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, json.JSONDecodeError):
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
for row in data.get("dns") or []:
    name = row.get("name") if isinstance(row, dict) else ""
    if isinstance(name, str) and name.startswith("jellyfin."):
        sys.exit(0)
sys.exit(1)
PY
}

# First boot has no handoff yet; POST /v1/tunnels includes Jellyfin then.
# A later run uses the claim token already stored beside that handoff.
sync_jellyfin_tunnel() {
  local enabled=$1
  local script="${TW_STACK_ROOT}/cloudflared-hosts.sh"
  [[ -f "$script" ]] || die "Missing cloudflared-hosts.sh"
  bash "$script" --jellyfin "$enabled"
}

if ! jellyfin_requested; then
  # Only an explicit off removes the host. A default of 0, with no Jellyfin
  # name on the saved handoff, does not call the control plane.
  if [[ "$JELLYFIN_EXPLICIT" == "1" ]] && handoff_has_jellyfin; then
    sync_jellyfin_tunnel 0
  fi
  log "TWS_JELLYFIN is off — Jellyfin install skipped"
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

JELLYFIN_D="$(jellyfin_domain "$MAIN_DOMAIN")"
ADMIN_USER="${JELLYFIN_ADMIN_USER:-${YUNOHOST_ADMIN_USER:-twsowner}}"
JELLYFIN_URL="https://${JELLYFIN_D}/"

jellyfin_python() {
  local candidate
  for candidate in \
    "${TW_STACK_ROOT}/family/dashboard/tinywebstack_dashboard/jellyfin.py" \
    "${TW_STACK_ROOT}/../family/dashboard/tinywebstack_dashboard/jellyfin.py"
  do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  die "Missing jellyfin.py (cannot secure the LDAP new-user default)"
}

link_main_wildcard_cert() {
  local main=$1 host=$2
  local main_crt="/etc/yunohost/certs/${main}/crt.pem"
  local main_key="/etc/yunohost/certs/${main}/key.pem"
  [[ -f "$main_crt" && -f "$main_key" ]] || return 1
  # Fixed string: dots in the family name must not be regex wildcards.
  if ! openssl x509 -in "$main_crt" -noout -text 2>/dev/null | grep -F -q "DNS:*.${main}"; then
    return 1
  fi
  local dest="/etc/yunohost/certs/${host}"
  mkdir -p "$dest"
  install -m 644 "$main_crt" "${dest}/crt.pem"
  install -m 600 "$main_key" "${dest}/key.pem"
  yunohost tools regen-conf --force 2>/dev/null || systemctl reload nginx 2>/dev/null || true
  log "Linked wildcard certificate from ${main} onto ${host}"
  return 0
}

install_jellyfin_tls() {
  local host=$1
  if [[ -x "${TW_STACK_ROOT}/vm/yunohost-lab-tls.sh" ]]; then
    "${TW_STACK_ROOT}/vm/yunohost-lab-tls.sh" "$host" || log "WARN: lab TLS for ${host}"
  fi
  if [[ "${TWS_MODE:-}" == "production" || "${TWS_TLS_SINGLE_SAN_CERT:-0}" == "1" ]]; then
    if link_main_wildcard_cert "$MAIN_DOMAIN" "$host"; then
      return 0
    fi
    local crt="/etc/yunohost/certs/${host}/crt.pem"
    if openssl x509 -in "$crt" -noout -issuer 2>/dev/null | grep -qi "Let's Encrypt"; then
      return 0
    fi
    local le_args=()
    if [[ -n "${TWS_LE_EMAIL:-}" ]]; then
      le_args+=(--email "$TWS_LE_EMAIL")
    fi
    if ! yunohost domain cert install "$host" "${le_args[@]}" --no-checks 2>/dev/null; then
      yunohost domain cert install "$host" "${le_args[@]}" \
        || log "WARN: Let's Encrypt failed for ${host}; retry: yunohost domain cert install ${host}"
    fi
  fi
}

if ! yunohost domain list 2>/dev/null | grep -qw "$JELLYFIN_D"; then
  yunohost domain add "$JELLYFIN_D"
fi
install_jellyfin_tls "$JELLYFIN_D"

if yunohost app list 2>/dev/null | grep -qw jellyfin; then
  log "App jellyfin already installed"
else
  # visitors: the package documents a public URL so phone and TV clients can reach
  # Jellyfin's own login. auth_header stays false upstream. LDAP, not SSOwat,
  # decides who gets a session. The admin permission is one YunoHost user, never
  # the kids group.
  yunohost app install jellyfin --args \
    "domain=${JELLYFIN_D}&path=/&init_main_permission=visitors&init_admin_permission=${ADMIN_USER}"
fi

DATA_DIR="$(yunohost app setting jellyfin data_dir 2>/dev/null | tr -d '[:space:]' || true)"
LDAP_XML="${DATA_DIR}/plugins/configurations/LDAP-Auth.xml"
if [[ -z "$DATA_DIR" || ! -f "$LDAP_XML" ]]; then
  die "Jellyfin LDAP config not found; child library default was not secured. Refusing to finish."
fi

PY="$(jellyfin_python)"
LDAP_STATUS="$(python3 "$PY" --secure-ldap-xml "$LDAP_XML")"
case "$LDAP_STATUS" in
  updated|unchanged) ;;
  *) die "Unexpected Jellyfin LDAP helper status" ;;
esac
if id jellyfin >/dev/null 2>&1; then
  chown jellyfin:jellyfin "$LDAP_XML"
fi
chmod 640 "$LDAP_XML"
if [[ "$LDAP_STATUS" == "updated" ]]; then
  yunohost service restart jellyfin \
    || systemctl restart jellyfin \
    || die "Jellyfin did not restart after the LDAP default change"
  log "Jellyfin LDAP new-user default set to no libraries"
else
  log "Jellyfin LDAP new-user default already grants no libraries"
fi

if [[ -x "${TW_STACK_ROOT}/vm/family-groups.sh" ]]; then
  bash "${TW_STACK_ROOT}/vm/family-groups.sh" || die "family-groups after jellyfin failed"
fi

ENV_FILE="/etc/tinywebstack/dashboard.env"
if [[ -f "$ENV_FILE" ]]; then
  if grep -q '^TWS_JELLYFIN_URL=' "$ENV_FILE"; then
    sed -i "s|^TWS_JELLYFIN_URL=.*|TWS_JELLYFIN_URL=${JELLYFIN_URL}|" "$ENV_FILE"
  else
    printf 'TWS_JELLYFIN_URL=%s\n' "$JELLYFIN_URL" >>"$ENV_FILE"
  fi
  if systemctl is-enabled tinywebstack-family-dashboard.service >/dev/null 2>&1; then
    systemctl restart tinywebstack-family-dashboard.service \
      || log "WARN: dashboard did not restart to pick up the Jellyfin address"
  fi
else
  log "WARN: ${ENV_FILE} missing — re-run install-jellyfin.sh after the family dashboard"
fi

if handoff_ready; then
  sync_jellyfin_tunnel 1
fi

log "Jellyfin ready at ${JELLYFIN_URL} (sign-in is LDAP username and password, not single sign-on)"
