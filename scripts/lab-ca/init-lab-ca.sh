#!/usr/bin/env bash
# Create a long-lived lab CA for HTTPS + Matrix federation between test nodes.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config

require_cmd openssl

LAB_DIR="${TW_STACK_LAB_CA_DIR:-${TW_STACK_SECRETS_DIR}/lab-ca}"
CA_KEY="${LAB_DIR}/lab-ca.key.pem"
CA_CERT="${LAB_DIR}/lab-ca.crt.pem"

if [[ -f "$CA_CERT" && -f "$CA_KEY" ]]; then
  log "Lab CA already exists in ${LAB_DIR}"
  exit 0
fi

if dry_run_is_active; then
  log "DRY_RUN: would create lab CA in ${LAB_DIR}"
  exit 0
fi

ensure_dir "$LAB_DIR"
chmod 700 "$LAB_DIR"

openssl genrsa -out "$CA_KEY" 4096
chmod 600 "$CA_KEY"
openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
  -subj "/CN=tinywebStack Lab CA/O=tinywebStack/C=ZZ" \
  -out "$CA_CERT"

log "Lab CA ready: ${CA_CERT}"
