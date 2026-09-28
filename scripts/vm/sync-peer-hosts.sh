#!/usr/bin/env bash
# Merge peer node hostnames into /etc/hosts (run on VM as root).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"

PEERS_FILE="${TW_STACK_ROOT}/peers.hosts"
HOSTS="/etc/hosts"
MARK_BEGIN="# tinywebstack-peer-nodes-begin"
MARK_END="# tinywebstack-peer-nodes-end"

if [[ ! -f "$PEERS_FILE" ]]; then
  log "No peers.hosts at ${PEERS_FILE}; skipping"
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

TMP="$(mktemp)"
{
  echo "$MARK_BEGIN"
  cat "$PEERS_FILE"
  echo "$MARK_END"
} > "$TMP"

awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
  $0 == begin { skip=1; next }
  $0 == end { skip=0; next }
  !skip { print }
' "$HOSTS" > "${HOSTS}.tmp"
cat "$TMP" >> "${HOSTS}.tmp"
mv "${HOSTS}.tmp" "$HOSTS"
rm -f "$TMP"
log "Updated ${HOSTS} with peer entries"
