#!/usr/bin/env bash
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config

usage() {
  echo "Usage: destroy-vm.sh NODE_NAME [--remove-disk]"
  exit 1
}

[[ $# -ge 1 ]] || usage

NODE_NAME=$1
REMOVE_DISK=0
[[ "${2:-}" == "--remove-disk" ]] && REMOVE_DISK=1

DOMAIN="$(vm_domain_name "$NODE_NAME")"
DISK="$(vm_disk_path "$NODE_NAME")"

require_cmd virsh

if ! virsh dominfo "$DOMAIN" >/dev/null 2>&1; then
  log "VM ${DOMAIN} does not exist — nothing to do"
  exit 0
fi

if dry_run_is_active; then
  log "DRY_RUN: virsh destroy ${DOMAIN}; virsh undefine ${DOMAIN}"
  exit 0
fi

virsh destroy "$DOMAIN" 2>/dev/null || true
virsh undefine "$DOMAIN" --remove-all-storage 2>/dev/null || virsh undefine "$DOMAIN"

if [[ "$REMOVE_DISK" == 1 && -f "$DISK" ]]; then
  rm -f "$DISK"
  log "Removed disk ${DISK}"
fi

log "Destroyed ${DOMAIN}"
