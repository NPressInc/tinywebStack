#!/usr/bin/env bash
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config

require_cmd curl
if ! dry_run_is_active; then
  require_cmd qemu-img
fi

DEBIAN_VERSION="${DEBIAN_VERSION:-12}"
ARCH="${ARCH:-amd64}"
IMAGE_NAME="debian-${DEBIAN_VERSION}-genericcloud-${ARCH}"
BASE_URL="https://cloud.debian.org/images/cloud/bookworm/latest"

ensure_dir "${TW_STACK_IMAGE_DIR}"

TARGET="${DEBIAN_CLOUD_IMAGE:-${TW_STACK_IMAGE_DIR}/${IMAGE_NAME}.qcow2}"
TMP="${TARGET}.partial"

if [[ -f "$TARGET" ]]; then
  log "Cloud image already present: ${TARGET}"
  exit 0
fi

if dry_run_is_active; then
  log "DRY_RUN: would download ${IMAGE_NAME}.qcow2 to ${TARGET}"
  exit 0
fi

URL="${BASE_URL}/${IMAGE_NAME}.qcow2"
log "Downloading ${URL} → ${TMP}"
run_or_echo curl -fL --retry 3 -o "$TMP" "$URL"
run_or_echo qemu-img convert -O qcow2 "$TMP" "$TARGET"
run_or_echo rm -f "$TMP"
log "Ready: ${TARGET}"
