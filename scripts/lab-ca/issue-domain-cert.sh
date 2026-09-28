#!/usr/bin/env bash
# Issue a domain TLS cert signed by the lab CA (run on spark).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config

usage() {
  echo "Usage: issue-domain-cert.sh FQDN"
  exit 1
}

[[ $# -eq 1 ]] || usage
FQDN=$1

require_cmd openssl
"${TW_STACK_ROOT}/scripts/lab-ca/init-lab-ca.sh"

LAB_DIR="${TW_STACK_LAB_CA_DIR:-${TW_STACK_SECRETS_DIR}/lab-ca}"
OUT_DIR="${LAB_DIR}/certs/${FQDN}"
CA_KEY="${LAB_DIR}/lab-ca.key.pem"
CA_CERT="${LAB_DIR}/lab-ca.crt.pem"

if dry_run_is_active; then
  log "DRY_RUN: would issue cert for ${FQDN} under ${OUT_DIR}"
  exit 0
fi

ensure_dir "$OUT_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl genrsa -out "${TMP}/key.pem" 2048
openssl req -new -key "${TMP}/key.pem" -out "${TMP}/csr.pem" \
  -subj "/CN=${FQDN}/O=tinywebStack Lab Node/C=ZZ"
printf 'subjectAltName=DNS:%s\n' "$FQDN" > "${TMP}/san.cnf"
openssl x509 -req -in "${TMP}/csr.pem" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "${TMP}/crt.pem" -days 825 -sha256 -extfile "${TMP}/san.cnf"

cat "${TMP}/crt.pem" "$CA_CERT" > "${OUT_DIR}/fullchain.pem"
cp "${TMP}/key.pem" "${OUT_DIR}/privkey.pem"
chmod 600 "${OUT_DIR}/privkey.pem"
cp "$CA_CERT" "${OUT_DIR}/lab-ca.crt.pem"

log "Issued lab cert for ${FQDN} → ${OUT_DIR}"
