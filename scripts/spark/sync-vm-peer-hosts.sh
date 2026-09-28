#!/usr/bin/env bash
# Build peers.hosts for one node and push to the VM.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/scripts/lib/domains.sh"
load_config
ensure_libvirt_system_uri

usage() {
  echo "Usage: sync-vm-peer-hosts.sh NODE_NAME VM_IP_OR_SSH_TARGET"
  exit 1
}

[[ $# -eq 2 ]] || usage
SELF_NAME=$1
TARGET=$2

PEERS_OUT="${TW_STACK_SECRETS_DIR}/peers.${SELF_NAME}.hosts"
TMP="$(mktemp)"
: > "$TMP"

while read -r name domain _rest; do
  [[ -n "$name" ]] || continue
  [[ "$name" == "$SELF_NAME" ]] && continue
  domain="${domain:-${name}.${TEST_DOMAIN_SUFFIX}}"
  dom="$(vm_domain_name "$name")"
  ip=""
  if virsh dominfo "$dom" >/dev/null 2>&1; then
    ip="$(virsh domifaddr "$dom" 2>/dev/null | awk '/ipv4/ {print $4; exit}' | cut -d/ -f1)"
  fi
  if [[ -z "$ip" ]]; then
    log "WARN: no IP for peer ${dom}; skip"
    continue
  fi
  mapfile -t _fqdns < <(node_all_domains "$domain")
  for fqdn in "${_fqdns[@]}"; do
    [[ -n "$fqdn" ]] || continue
    printf '%s\t%s\n' "$ip" "$fqdn" >>"$TMP"
  done
done < <(read_nodes_conf)

install -m 644 "$TMP" "$PEERS_OUT"
rm -f "$TMP"

TW_STACK_PEERS_HOSTS_FILE="$PEERS_OUT" \
  "${TW_STACK_ROOT}/scripts/vm/remote-run.sh" "$TARGET" sync-peer-hosts.sh

log "Peer /etc/hosts updated on ${TARGET} (node ${SELF_NAME})"
