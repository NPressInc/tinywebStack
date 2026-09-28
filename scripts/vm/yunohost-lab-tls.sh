#!/usr/bin/env bash
# Install lab-CA-signed cert into YunoHost cert store (run on VM as root).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"

usage() {
  echo "Usage: yunohost-lab-tls.sh MAIN_DOMAIN"
  exit 1
}

[[ $# -eq 1 ]] || usage
MAIN_DOMAIN=$1

CERT_SRC="${TW_STACK_ROOT}/lab-certs/${MAIN_DOMAIN}"
if [[ ! -f "${CERT_SRC}/fullchain.pem" || ! -f "${CERT_SRC}/privkey.pem" ]]; then
  log "No lab cert staged at ${CERT_SRC}; keeping YunoHost self-signed cert"
  exit 0
fi

DEST="/etc/yunohost/certs/${MAIN_DOMAIN}"
mkdir -p "$DEST"
install -m 644 "${CERT_SRC}/fullchain.pem" "${DEST}/crt.pem"
install -m 600 "${CERT_SRC}/privkey.pem" "${DEST}/key.pem"
ln -sfn "${MAIN_DOMAIN}" "/etc/yunohost/certs/${MAIN_DOMAIN}-live" 2>/dev/null || true

yunohost tools regen-conf --force || true
log "Installed lab TLS cert for ${MAIN_DOMAIN}"
