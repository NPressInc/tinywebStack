#!/usr/bin/env bash
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config
ensure_libvirt_system_uri

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
SEED_ISO="$(vm_seed_iso_path "$NODE_NAME")"

require_cmd virsh

if ! virsh dominfo "$DOMAIN" >/dev/null 2>&1; then
  log "VM ${DOMAIN} does not exist — nothing to do"
  exit 0
fi

if dry_run_is_active; then
  log "DRY_RUN: virsh destroy ${DOMAIN}"
  log "DRY_RUN: virsh undefine ${DOMAIN} --nvram --remove-all-storage (else --nvram, else --remove-all-storage, else plain)"
  if [[ "$REMOVE_DISK" == 1 ]]; then
    log "DRY_RUN: rm -f ${DISK}"
    if [[ -f "$SEED_ISO" ]]; then
      log "DRY_RUN: rm -f ${SEED_ISO}"
    fi
  fi
  exit 0
fi

virsh destroy "$DOMAIN" 2>/dev/null || true

virsh undefine "$DOMAIN" --nvram --remove-all-storage 2>/dev/null \
  || virsh undefine "$DOMAIN" --nvram 2>/dev/null \
  || virsh undefine "$DOMAIN" --remove-all-storage 2>/dev/null \
  || virsh undefine "$DOMAIN" 2>/dev/null \
  || true

if virsh dominfo "$DOMAIN" >/dev/null 2>&1; then
  die "Failed to undefine libvirt domain ${DOMAIN} (still defined; try: virsh undefine ${DOMAIN} --nvram)"
fi

if [[ "$REMOVE_DISK" == 1 ]]; then
  if [[ -f "$DISK" ]]; then
    rm -f "$DISK"
    log "Removed disk ${DISK}"
  fi
  if [[ -f "$SEED_ISO" ]]; then
    rm -f "$SEED_ISO"
    log "Removed cloud-init seed ${SEED_ISO}"
  fi
fi

log "Destroyed ${DOMAIN}"
