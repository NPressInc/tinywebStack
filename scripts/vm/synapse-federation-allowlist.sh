#!/usr/bin/env bash
# Restrict Matrix federation to an explicit domain allowlist (conf.d snippet).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

usage() {
  cat <<'EOF'
Usage: synapse-federation-allowlist.sh LOCAL_DOMAIN ALLOWED_DOMAIN [ALLOWED_DOMAIN...]

Writes /etc/matrix-synapse/conf.d/tinywebstack-federation.yaml and restarts Synapse.
Uses federation_custom_ca_list when lab CA PEM is present.
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage

LOCAL_DOMAIN=$1
shift
ALLOWED=("$@")

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

CONF_D="/etc/matrix-synapse/conf.d"
SNIPPET="${CONF_D}/tinywebstack-federation.yaml"
LAB_CA_PEM="${CONF_D}/tinywebstack-lab-ca.pem"
LAB_CA_SRC="${TW_STACK_ROOT}/lab-certs/lab-ca.crt.pem"

[[ -d "$CONF_D" ]] || mkdir -p "$CONF_D"

TMP="$(mktemp)"
{
  echo "# Managed by tinywebStack — do not edit on the homeserver.yaml master file"
  echo "federation_domain_whitelist:"
  for d in "${ALLOWED[@]}"; do
    printf '  - "%s"\n' "$d"
  done
  if [[ -f "$LAB_CA_SRC" ]]; then
    cp "$LAB_CA_SRC" "$LAB_CA_PEM"
    chmod 644 "$LAB_CA_PEM"
    echo "federation_custom_ca_list:"
    printf '  - "%s"\n' "$LAB_CA_PEM"
  else
    echo "# Lab-only fallback when lab CA is not deployed:"
    echo "federation_verify_certificates: false"
  fi
} > "$TMP"

if [[ -f "$SNIPPET" ]] && cmp -s "$TMP" "$SNIPPET"; then
  rm -f "$TMP"
  echo "Federation snippet unchanged on ${LOCAL_DOMAIN}"
  exit 0
fi

mv "$TMP" "$SNIPPET"
systemctl restart matrix-synapse
echo "Federation allowlist updated on ${LOCAL_DOMAIN}: ${ALLOWED[*]}"
