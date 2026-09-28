#!/usr/bin/env bash
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config
ensure_libvirt_system_uri

EXTRA_IPS=("$@")

idx=0
while read -r name _domain _rest; do
  [[ -n "$name" ]] || continue
  ip=""
  if [[ $idx -lt ${#EXTRA_IPS[@]} ]]; then
    ip="${EXTRA_IPS[$idx]}"
  fi
  if [[ -z "$ip" ]]; then
    dom="$(vm_domain_name "$name")"
    ip="$(virsh domifaddr "$dom" 2>/dev/null | awk '/ipv4/ {print $4; exit}' | cut -d/ -f1)"
  fi
  [[ -n "$ip" ]] || die "No IP for ${name}; pass IPs as args or wait for DHCP"
  "${TW_STACK_ROOT}/scripts/spark/sync-vm-peer-hosts.sh" "$name" "$ip"
  idx=$((idx + 1))
done < <(read_nodes_conf)
