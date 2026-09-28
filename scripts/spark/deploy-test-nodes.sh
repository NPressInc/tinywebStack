#!/usr/bin/env bash
# Create all VMs defined in config/nodes.conf (idempotent).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config
ensure_libvirt_system_uri

if ! dry_run_is_active; then
  require_cmd virt-install virsh
fi

"${TW_STACK_ROOT}/scripts/spark/ensure-libvirt-storage.sh"
"${TW_STACK_ROOT}/scripts/spark/fetch-debian-cloud-image.sh"
"${TW_STACK_ROOT}/scripts/spark/ensure-node-secrets.sh"

while read -r name domain ram vcpus disk; do
  [[ -n "$name" ]] || continue
  ram=${ram:-${DEFAULT_VM_RAM_MB}}
  vcpus=${vcpus:-${DEFAULT_VM_VCPUS}}
  disk=${disk:-${DEFAULT_VM_DISK_GB}}
  log "Ensuring VM for node ${name} (${domain})"
  "${TW_STACK_ROOT}/scripts/spark/create-vm.sh" "$name" "$domain" "$ram" "$vcpus" "$disk"
done < <(read_nodes_conf)

log "All nodes ensured. Next: docs/test-nodes.md (DNS, YunoHost install, apps, federation)."
