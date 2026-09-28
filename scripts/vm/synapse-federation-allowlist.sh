#!/usr/bin/env bash
# Restrict Matrix federation (conf.d snippet + lab CA + private IP whitelist).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

usage() {
  cat <<'EOF'
Usage: synapse-federation-allowlist.sh LOCAL_DOMAIN ALLOWED_DOMAIN [ALLOWED_DOMAIN...]
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
LAB_CA_DST="/etc/matrix-synapse/tinywebstack-lab-ca.pem"
LAB_CA_SRC="${TW_STACK_ROOT}/lab-certs/lab-ca.crt.pem"
IP_RANGE="${FEDERATION_IP_RANGE_WHITELIST:-192.168.122.0/24}"

[[ -d "$CONF_D" ]] || mkdir -p "$CONF_D"

if [[ -f "$LAB_CA_SRC" ]]; then
  install -m 644 "$LAB_CA_SRC" "$LAB_CA_DST"
else
  rm -f "$LAB_CA_DST"
fi

TMP="$(mktemp)"
{
  echo "# Managed by tinywebStack"
  echo "federation_domain_whitelist:"
  for d in "${ALLOWED[@]}"; do
    printf '  - "%s"\n' "$d"
  done
  echo "ip_range_whitelist:"
  printf '  - "%s"\n' "$IP_RANGE"
  if [[ -f "$LAB_CA_DST" ]]; then
    echo "federation_custom_ca_list:"
    printf '  - "%s"\n' "$LAB_CA_DST"
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
if getent group synapse >/dev/null 2>&1; then
  chown root:synapse "$SNIPPET"
  chmod 640 "$SNIPPET"
elif getent group matrix-synapse >/dev/null 2>&1; then
  chown root:matrix-synapse "$SNIPPET"
  chmod 640 "$SNIPPET"
else
  chmod 644 "$SNIPPET"
fi

restart_synapse() {
  if systemctl list-unit-files synapse.service >/dev/null 2>&1; then
    systemctl restart synapse
  elif systemctl list-unit-files matrix-synapse.service >/dev/null 2>&1; then
    systemctl restart matrix-synapse
  else
    systemctl restart synapse 2>/dev/null || systemctl restart matrix-synapse
  fi
}

restart_synapse
echo "Federation allowlist updated on ${LOCAL_DOMAIN}: ${ALLOWED[*]}"
