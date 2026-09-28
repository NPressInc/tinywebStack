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
      # virt-install 4.1+ on spark: --boot uefi is enough; flash disks with unit= fail.
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
