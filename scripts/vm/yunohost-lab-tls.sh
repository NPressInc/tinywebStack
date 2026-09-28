#!/usr/bin/env bash
# Install lab-CA-signed cert into YunoHost cert store (run on VM as root).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"

usage() {
  echo "Usage: yunohost-lab-tls.sh FQDN"
  exit 1
}

[[ $# -eq 1 ]] || usage
FQDN=$1

CERT_SRC="${TW_STACK_ROOT}/lab-certs/${FQDN}"
if [[ ! -f "${CERT_SRC}/fullchain.pem" || ! -f "${CERT_SRC}/privkey.pem" ]]; then
  log "No lab cert staged at ${CERT_SRC}; keeping existing cert"
  exit 0
fi

DEST="/etc/yunohost/certs/${FQDN}"
mkdir -p "$DEST"
if [[ -f "${DEST}/crt.pem" && -f "${DEST}/key.pem" ]] \
  && cmp -s "${CERT_SRC}/fullchain.pem" "${DEST}/crt.pem" \
  && cmp -s "${CERT_SRC}/privkey.pem" "${DEST}/key.pem"; then
  log "Lab TLS cert unchanged for ${FQDN}"
  exit 0
fi

install -m 644 "${CERT_SRC}/fullchain.pem" "${DEST}/crt.pem"
install -m 600 "${CERT_SRC}/privkey.pem" "${DEST}/key.pem"

yunohost tools regen-conf --force || true
systemctl reload nginx 2>/dev/null || systemctl try-reload-or-restart nginx || true
if systemctl is-active --quiet synapse 2>/dev/null; then
  systemctl restart synapse
elif systemctl is-active --quiet matrix-synapse 2>/dev/null; then
  systemctl restart matrix-synapse
fi
log "Installed lab TLS cert for ${FQDN}"
