#!/usr/bin/env bash
# Restrict Matrix federation (conf.d snippet + lab CA + private IP whitelist).
#
# Modes:
#   Static (default, lab flow unchanged):
#     synapse-federation-allowlist.sh LOCAL_DOMAIN ALLOWED_DOMAIN [ALLOWED_DOMAIN...]
#   Dashboard state file (L2.2, applies the dashboard's federation state):
#     synapse-federation-allowlist.sh --from-state LOCAL_DOMAIN STATE_FILE
#     synapse-federation-allowlist.sh --from-state LOCAL_DOMAIN base64:BASE64JSON
#
# STATE_FILE is the dashboard federation state JSON (TWS_FEDERATION_STATE_PATH,
# default /etc/tinywebstack/federation-state.json). The base64: form lets
# scripts/vm/remote-run.sh callers push state without a prior file on the VM.
# DRY_RUN=1 prints the rendered Synapse yaml to stdout (no root, no writes).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

usage() {
  cat <<'EOF'
Usage:
  synapse-federation-allowlist.sh LOCAL_DOMAIN ALLOWED_DOMAIN [ALLOWED_DOMAIN...]
  synapse-federation-allowlist.sh --from-state LOCAL_DOMAIN STATE_FILE
  synapse-federation-allowlist.sh --from-state LOCAL_DOMAIN base64:BASE64JSON

STATE_FILE is a dashboard federation state JSON (TWS_FEDERATION_STATE_PATH,
default /etc/tinywebstack/federation-state.json). DRY_RUN=1 prints the
rendered yaml to stdout instead of applying it.
EOF
  exit 1
}

FROM_STATE=0
STATE_REF=""
if [[ "${1:-}" == "--from-state" ]]; then
  FROM_STATE=1
  shift
  [[ $# -eq 2 ]] || usage
  LOCAL_DOMAIN=$1
  STATE_REF=$2
else
  [[ $# -ge 2 ]] || usage
  LOCAL_DOMAIN=$1
  shift
fi

CONF_D="/etc/matrix-synapse/conf.d"
SNIPPET="${CONF_D}/tinywebstack-federation.yaml"
LAB_CA_DST="/etc/matrix-synapse/tinywebstack-lab-ca.pem"
LAB_CA_SRC="${TW_STACK_ROOT}/lab-certs/lab-ca.crt.pem"
IP_RANGE="${FEDERATION_IP_RANGE_WHITELIST:-192.168.122.0/24}"

# --- resolve the allowed domain list for the chosen mode -------------------
ALLOWED=()
if [[ "$FROM_STATE" -eq 1 ]]; then
  if [[ "$STATE_REF" == base64:* ]]; then
    STATE_JSON_TMP="$(mktemp)"
    trap 'rm -f "${STATE_JSON_TMP:-}"' EXIT
    printf '%s' "${STATE_REF#base64:}" | base64 -d > "$STATE_JSON_TMP"
    STATE_FILE="$STATE_JSON_TMP"
  else
    STATE_FILE="$STATE_REF"
    [[ -f "$STATE_FILE" ]] || die "Missing federation state file: ${STATE_FILE}"
  fi
  mapfile -t ALLOWED < <(python3 - "$STATE_FILE" "$LOCAL_DOMAIN" <<'PY'
import json
import sys
from pathlib import Path

try:
    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    sys.exit(f"Unreadable federation state file: {exc}")
if not isinstance(data, dict):
    sys.exit("Federation state must be a JSON object")
domains = data.get("trusted_domains")
if not isinstance(domains, list):
    sys.exit("Federation state trusted_domains must be a list")
local = sys.argv[2].strip().lower()
seen = set()
for d in domains:
    d = str(d).strip().lower()
    if d and d != local and d not in seen:
        seen.add(d)
        print(d)
PY
  )
else
  ALLOWED=("$@")
fi

if [[ "$FROM_STATE" -eq 1 && ${#ALLOWED[@]} -eq 0 ]]; then
  # An empty whitelist list would render as YAML null, which Synapse reads as
  # "allow all federation" — refuse instead. Remove peers via the dashboard,
  # or run the static mode with an explicit domain when intentionally open.
  die "Federation state has no peer domains for ${LOCAL_DOMAIN}; refusing to render an open whitelist"
fi

render_snippet() {
  echo "# Managed by tinywebStack"
  echo "federation_domain_whitelist:"
  local d
  for d in "${ALLOWED[@]+"${ALLOWED[@]}"}"; do
    printf '  - "%s"\n' "$d"
  done
  echo "ip_range_whitelist:"
  printf '  - "%s"\n' "$IP_RANGE"
  if [[ -f "$LAB_CA_SRC" || -f "$LAB_CA_DST" ]]; then
    echo "federation_custom_ca_list:"
    printf '  - "%s"\n' "$LAB_CA_DST"
  else
    echo "# Lab-only fallback when lab CA is not deployed:"
    echo "federation_verify_certificates: false"
  fi
}

if dry_run_is_active; then
  log "DRY_RUN: rendered Synapse federation yaml for ${LOCAL_DOMAIN}"
  render_snippet
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

[[ -d "$CONF_D" ]] || mkdir -p "$CONF_D"

if [[ -f "$LAB_CA_SRC" ]]; then
  install -m 644 "$LAB_CA_SRC" "$LAB_CA_DST"
else
  rm -f "$LAB_CA_DST"
fi

TMP="$(mktemp)"
render_snippet > "$TMP"

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
echo "Federation allowlist updated on ${LOCAL_DOMAIN}: ${ALLOWED[*]:-none}"
