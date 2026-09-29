#!/usr/bin/env bash
# Lab-only: append tinywebStack lab CA to Mobilizon's bundled Erlang CA stores (castore/certifi).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"

MARKER="# tinywebstack-lab-ca-append"

usage() {
  echo "Usage: mobilizon-lab-ca-trust.sh"
  exit 1
}

[[ $# -eq 0 ]] || usage

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

LAB_CA="${TW_STACK_ROOT}/lab-certs/lab-ca.crt.pem"
if [[ ! -f "$LAB_CA" && -f /etc/tinywebstack/lab-ca.pem ]]; then
  LAB_CA="/etc/tinywebstack/lab-ca.pem"
fi
[[ -f "$LAB_CA" ]] || {
  log "No lab CA present — Mobilizon bundled CA patch skipped (production or unstaged certs)"
  exit 0
}

INSTALL_DIR="$(yunohost app setting mobilizon app_dir 2>/dev/null | tr -d '[:space:]' || true)"
INSTALL_DIR="${INSTALL_DIR:-/var/www/mobilizon}"
[[ -d "$INSTALL_DIR" ]] || die "Mobilizon install_dir missing: ${INSTALL_DIR}"

install -d -m 755 /etc/tinywebstack
install -m 644 "$LAB_CA" /etc/tinywebstack/lab-ca.pem

append_lab_ca() {
  local bundle=$1
  [[ -f "$bundle" ]] || return 0
  if grep -qF "$MARKER" "$bundle" 2>/dev/null; then
    return 0
  fi
  {
    echo ""
    echo "$MARKER"
    cat /etc/tinywebstack/lab-ca.pem
  } >>"$bundle"
  log "Appended lab CA to ${bundle}"
}

while IFS= read -r -d '' bundle; do
  append_lab_ca "$bundle"
done < <(find "$INSTALL_DIR" -type f \( -name 'cacerts.pem' -o -name 'ca-certificates.crt' \) -print0 2>/dev/null)

if systemctl list-unit-files mobilizon.service >/dev/null 2>&1; then
  systemctl restart mobilizon
else
  yunohost service restart mobilizon 2>/dev/null || true
fi

log "Mobilizon bundled CA trust updated (lab only; re-run after Mobilizon package upgrades)"
