#!/usr/bin/env bash
# Family-layer Mobilizon settings (LDAP/SSO registrations off, tinywebStack config snippet).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
load_config

usage() {
  echo "Usage: mobilizon-family-config.sh MAIN_DOMAIN"
  exit 1
}

[[ $# -eq 1 ]] || usage
MAIN_DOMAIN=$1

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

if ! yunohost app list 2>/dev/null | grep -qw mobilizon; then
  die "Mobilizon is not installed"
fi

INSTALL_DIR="$(yunohost app setting mobilizon app_dir 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -z "$INSTALL_DIR" && -f /etc/yunohost/apps/mobilizon/settings.yml ]]; then
  INSTALL_DIR="$(grep -E '^[[:space:]]*install_dir:' /etc/yunohost/apps/mobilizon/settings.yml | awk '{print $2}' | tr -d '\"' | head -1)"
fi
INSTALL_DIR="${INSTALL_DIR:-/var/www/mobilizon}"
CONFIG="${INSTALL_DIR}/config.exs"
SNIPPET="/etc/tinywebstack/mobilizon-family.exs"
MARKER="# tinywebstack mobilizon family layer"

[[ -f "$CONFIG" ]] || die "Missing Mobilizon config ${CONFIG}"

install -d -m 755 /etc/tinywebstack
cat >"$SNIPPET" <<'EXS'
import Config

config :mobilizon, :instance,
  registrations_open: false,
  federating: true,
  allow_relay: true

config :mobilizon, :restrictions,
  only_admin_can_create_groups: true
EXS
chmod 644 "$SNIPPET"

if ! grep -qF "$MARKER" "$CONFIG" 2>/dev/null; then
  cat >>"$CONFIG" <<EOF

${MARKER}
Code.eval_file("${SNIPPET}")
EOF
  log "Appended family Mobilizon snippet hook to ${CONFIG}"
fi

if systemctl list-unit-files mobilizon.service >/dev/null 2>&1; then
  systemctl restart mobilizon
else
  yunohost service restart mobilizon 2>/dev/null || true
fi

log "Mobilizon family config applied for ${MAIN_DOMAIN} (https://$(events_domain "$MAIN_DOMAIN")/)"
