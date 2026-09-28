#!/usr/bin/env bash
# Extra virt-install arguments per host architecture.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

virt_install_arch_args() {
  case "$(debian_cloud_arch)" in
    amd64)
      printf '%s\n' "--osinfo" "debian12"
      ;;
    arm64)
      printf '%s\n' \
        "--arch" "aarch64" \
        "--machine" "virt" \
        "--boot" "uefi" \
        "--osinfo" "debian12"
      ;;
    armhf)
      printf '%s\n' \
        "--arch" "armv7l" \
        "--machine" "virt" \
        "--boot" "uefi" \
        "--osinfo" "debian12"
      ;;
    *)
      die "No virt-install profile for $(debian_cloud_arch)"
      ;;
  esac
}

uefi_vars_path_for_vm() {
  local domain=$1
  printf '%s/%s/OVMF_VARS.fd' "${TW_STACK_VM_DIR}" "$domain"
}

prepare_uefi_vars() {
  local domain=$1
  local vars dir
  vars="$(uefi_vars_path_for_vm "$domain")"
  dir="$(dirname "$vars")"
  ensure_dir "$dir"
  if [[ -f "$vars" ]]; then
    return 0
  fi
  if [[ -f /usr/share/AAVMF/AAVMF_VARS.fd ]]; then
    cp /usr/share/AAVMF/AAVMF_VARS.fd "$vars"
  elif [[ -f /usr/share/OVMF/OVMF_VARS.fd ]]; then
    cp /usr/share/OVMF/OVMF_VARS.fd "$vars"
  elif dry_run_is_active; then
    log "DRY_RUN: would copy UEFI vars template to ${vars}"
    return 0
  else
    die "UEFI vars template not found (install qemu-efi-aarch64 or ovmf)"
  fi
}

virt_install_uefi_disk_args() {
  local domain=$1
  case "$(debian_cloud_arch)" in
    amd64) return 0 ;;
    arm64 | armhf)
      prepare_uefi_vars "$domain"
      if [[ -f /usr/share/AAVMF/AAVMF_CODE.fd ]]; then
        printf '%s\n' \
          "--disk" "path=/usr/share/AAVMF/AAVMF_CODE.fd,format=raw,readonly=on,device=flash,unit=0" \
          "--disk" "path=$(uefi_vars_path_for_vm "$domain"),format=raw,device=flash,unit=1"
      elif [[ -f /usr/share/qemu-efi-aarch64/QEMU_EFI.fd ]]; then
        printf '%s\n' \
          "--disk" "path=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd,format=raw,readonly=on,device=flash,unit=0" \
          "--disk" "path=$(uefi_vars_path_for_vm "$domain"),format=raw,device=flash,unit=1"
      elif dry_run_is_active; then
        log "DRY_RUN: skipping UEFI firmware disk args"
      else
        die "ARM UEFI firmware not found (install qemu-efi-aarch64)"
      fi
      ;;
  esac
}
