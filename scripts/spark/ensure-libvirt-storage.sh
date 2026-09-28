#!/usr/bin/env bash
# Ensure VM disk directory exists (libvirt pool dir can be created without sudo for libvirt group).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config
ensure_libvirt_system_uri

ensure_dir "${TW_STACK_VM_DIR}"
ensure_dir "${TW_STACK_IMAGE_DIR}"

POOL_NAME="${LIBVIRT_POOL_NAME:-tinywebstack}"

if dry_run_is_active; then
  log "DRY_RUN: would ensure libvirt pool ${POOL_NAME} → ${TW_STACK_VM_DIR}"
  exit 0
fi

if virsh pool-info "$POOL_NAME" >/dev/null 2>&1; then
  log "Libvirt pool ${POOL_NAME} already defined"
  virsh pool-start "$POOL_NAME" 2>/dev/null || true
  exit 0
fi

if virsh pool-list --all | grep -qw "$POOL_NAME"; then
  virsh pool-start "$POOL_NAME" 2>/dev/null || true
  exit 0
fi

virsh pool-define-as --name "$POOL_NAME" --type dir --target "$TW_STACK_VM_DIR"
virsh pool-build "$POOL_NAME"
virsh pool-start "$POOL_NAME"
virsh pool-autostart "$POOL_NAME"
log "Defined libvirt storage pool ${POOL_NAME} at ${TW_STACK_VM_DIR}"
