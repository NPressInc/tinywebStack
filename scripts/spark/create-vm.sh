#!/usr/bin/env bash
# Create (or skip if exists) one YunoHost test VM via virt-install + cloud-init.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config

usage() {
  cat <<'EOF'
Usage: create-vm.sh NODE_NAME FQDN [RAM_MB] [VCPUS] [DISK_GB]

Idempotent: if libvirt domain tws-NODE_NAME already exists, exits 0 without changes.
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage

NODE_NAME=$1
FQDN=$2
RAM_MB=${3:-${DEFAULT_VM_RAM_MB}}
VCPUS=${4:-${DEFAULT_VM_VCPUS}}
DISK_GB=${5:-${DEFAULT_VM_DISK_GB}}

DOMAIN="$(vm_domain_name "$NODE_NAME")"
DISK="$(vm_disk_path "$NODE_NAME")"

if ! dry_run_is_active; then
  require_cmd virt-install virsh qemu-img
fi

if [[ ! -f "${DEBIAN_CLOUD_IMAGE}" ]]; then
  if dry_run_is_active; then
    log "DRY_RUN: base image missing; skipping disk check"
  else
    die "Missing base image ${DEBIAN_CLOUD_IMAGE}; run fetch-debian-cloud-image.sh"
  fi
fi

if command -v virsh >/dev/null 2>&1 && virsh dominfo "$DOMAIN" >/dev/null 2>&1; then
  log "VM ${DOMAIN} already exists — skipping create"
  exit 0
fi

ensure_dir "$(dirname "$DISK")"
ensure_dir "${TW_STACK_VM_DIR}/${DOMAIN}/seed"

"${TW_STACK_ROOT}/scripts/spark/render-cloud-init.sh" "$NODE_NAME" "$FQDN"

SEED_ISO="${TW_STACK_VM_DIR}/${DOMAIN}/seed/cloud-init.iso"

if dry_run_is_active; then
  log "DRY_RUN: would create disk ${DISK} (${DISK_GB}G) from ${DEBIAN_CLOUD_IMAGE}"
  log "DRY_RUN: virt-install --name ${DOMAIN} ..."
  exit 0
fi

if [[ ! -f "$DISK" ]]; then
  qemu-img create -f qcow2 -F qcow2 -b "${DEBIAN_CLOUD_IMAGE}" "$DISK" "${DISK_GB}G"
fi

virt-install \
  --name "$DOMAIN" \
  --memory "$RAM_MB" \
  --vcpus "$VCPUS" \
  --import \
  --disk "path=${DISK},format=qcow2,bus=virtio" \
  --disk "path=${SEED_ISO},device=cdrom" \
  --network "network=${LIBVIRT_NETWORK},model=virtio" \
  --osinfo debian12 \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole

log "VM ${DOMAIN} created. DHCP address: virsh domifaddr ${DOMAIN} (may take a minute after first boot)"
