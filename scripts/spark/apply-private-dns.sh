#!/usr/bin/env bash
# Append static host entries on spark for test domains (idempotent block marker).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
MARKER_BEGIN="# tinywebstack-test-nodes-begin"
MARKER_END="# tinywebstack-test-nodes-end"

require_cmd virsh awk

TMP="$(mktemp)"
{
  echo "$MARKER_BEGIN"
  while read -r name domain _rest; do
    [[ -n "$name" ]] || continue
    domain="${domain:-${name}.${TEST_DOMAIN_SUFFIX}}"
    dom="$(vm_domain_name "$name")"
    ip=""
    if virsh dominfo "$dom" >/dev/null 2>&1; then
      ip="$(virsh domifaddr "$dom" 2>/dev/null | awk '/ipv4/ {print $4; exit}' | cut -d/ -f1)"
    fi
    if [[ -z "$ip" ]]; then
      log "WARN: no IP yet for ${dom}; using placeholder 127.0.0.1 — re-run after VMs boot"
      ip="127.0.0.1"
    fi
    printf '%s\t%s\n' "$ip" "$domain"
  done < <(read_nodes_conf)
  echo "$MARKER_END"
} > "$TMP"

if dry_run_is_active; then
  log "DRY_RUN: would merge into ${HOSTS_FILE}:"
  cat "$TMP"
  exit 0
fi

if [[ ! -w "$HOSTS_FILE" ]]; then
  die "Cannot write ${HOSTS_FILE}. Re-run with sudo or set HOSTS_FILE to a writable path."
fi

awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
  $0 == begin { skip=1; next }
  $0 == end { skip=0; next }
  !skip { print }
' "$HOSTS_FILE" > "${HOSTS_FILE}.tmp"
cat "$TMP" >> "${HOSTS_FILE}.tmp"
mv "${HOSTS_FILE}.tmp" "$HOSTS_FILE"
rm -f "$TMP"
log "Updated ${HOSTS_FILE} with test node names"
