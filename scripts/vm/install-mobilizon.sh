#!/usr/bin/env bash
# Install Mobilizon (YunoHost catalog) as the family events app (idempotent).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
# shellcheck source=scripts/lib/mobilizon_python_path.sh
source "${TW_STACK_ROOT}/lib/mobilizon_python_path.sh"
load_config

usage() {
  echo "Usage: install-mobilizon.sh MAIN_DOMAIN [NODE_NAME]"
  exit 1
}

[[ $# -ge 1 ]] || usage
MAIN_DOMAIN=$1
NODE_NAME=${2:-}
: "${NODE_NAME:=}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

EVENTS_APP="${EVENTS_APP:-mobilizon}"
if [[ "$EVENTS_APP" != "mobilizon" ]]; then
  log "EVENTS_APP=${EVENTS_APP} — Mobilizon install skipped"
  exit 0
fi

EVENTS_D="$(events_domain "$MAIN_DOMAIN")"
ADMIN_USER="${MOBILIZON_ADMIN_USER:-${YUNOHOST_ADMIN_USER:-twsowner}}"

install_app() {
  if yunohost app list 2>/dev/null | grep -qw mobilizon; then
    log "App mobilizon already installed"
    return 0
  fi
  yunohost app install mobilizon --args "domain=${EVENTS_D}&admin=${ADMIN_USER}"
}

install_mobilizon_lab_ca_trust() {
  local lab_ca="${TW_STACK_ROOT}/lab-certs/lab-ca.crt.pem"
  local dst="/etc/tinywebstack/lab-ca.pem"
  local combined="/etc/tinywebstack/mobilizon-combined-ca.pem"
  [[ -f "$lab_ca" ]] || return 0
  install -d -m 755 /etc/tinywebstack
  install -m 644 "$lab_ca" "$dst"
  cat /etc/ssl/certs/ca-certificates.crt "$lab_ca" >"$combined"
  chmod 644 "$combined"
  install -d -m 755 /etc/systemd/system/mobilizon.service.d
  cat >/etc/systemd/system/mobilizon.service.d/tinywebstack-lab-ca.conf <<EOF
[Service]
Environment=SSL_CERT_FILE=${combined}
Environment=ERLANG_SSL_CACERTFILE=${combined}
EOF
  systemctl daemon-reload
  systemctl restart mobilizon 2>/dev/null || yunohost service restart mobilizon 2>/dev/null || true
  log "Mobilizon systemd configured to trust lab CA (test lab only)"
}

if ! yunohost domain list 2>/dev/null | grep -qw "$EVENTS_D"; then
  yunohost domain add "$EVENTS_D"
fi

if [[ -x "${TW_STACK_ROOT}/vm/yunohost-lab-tls.sh" ]]; then
  "${TW_STACK_ROOT}/vm/yunohost-lab-tls.sh" "$EVENTS_D" || log "WARN: lab TLS for ${EVENTS_D}"
fi

install_app
install_mobilizon_lab_ca_trust
"${TW_STACK_ROOT}/vm/mobilizon-family-config.sh" "$MAIN_DOMAIN"

if [[ -x "${TW_STACK_ROOT}/vm/family-groups.sh" ]]; then
  "${TW_STACK_ROOT}/vm/family-groups.sh" || log "WARN: family-groups after mobilizon"
fi

log "Mobilizon (events) ready at https://${EVENTS_D}/"
