#!/usr/bin/env bash
# Render cloud-init ISO for a node (idempotent: overwrites seed ISO).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config

usage() {
  cat <<'EOF'
Usage: render-cloud-init.sh NODE_NAME FQDN [output_dir]

Renders meta-data, user-data, and network-config from templates and builds a seed ISO.
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage

NODE_NAME=$1
FQDN=$2
OUT_DIR=${3:-"${TW_STACK_VM_DIR}/$(vm_domain_name "$NODE_NAME")/seed"}

PROVISION_SSH_USER="${PROVISION_SSH_USER:-twsadmin}"

[[ -f "${ADMIN_SSH_PUBKEY}" ]] || die "ADMIN_SSH_PUBKEY not found: ${ADMIN_SSH_PUBKEY}"

ADMIN_SSH_PUBKEY_CONTENT="$(cat "${ADMIN_SSH_PUBKEY}")"
export NODE_NAME FQDN ADMIN_SSH_PUBKEY_CONTENT PROVISION_SSH_USER

ensure_dir "$OUT_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

render_tpl() {
  local src=$1 dest=$2
  sed -e "s/\${NODE_NAME}/${NODE_NAME}/g" \
      -e "s/\${FQDN}/${FQDN//\//\\/}/g" \
      -e "s/\${PROVISION_SSH_USER}/${PROVISION_SSH_USER}/g" \
      -e "s|\${ADMIN_SSH_PUBKEY_CONTENT}|${ADMIN_SSH_PUBKEY_CONTENT}|g" \
      "$src" > "$dest"
}

for tpl in meta-data user-data network-config; do
  render_tpl "${TW_STACK_ROOT}/templates/cloud-init/${tpl}.yaml.tpl" "${TMP}/${tpl}"
done

ISO="${OUT_DIR}/cloud-init.iso"
if dry_run_is_active; then
  mkdir -p "$OUT_DIR"
  cp "${TMP}/user-data" "${OUT_DIR}/user-data.rendered"
  log "DRY_RUN: rendered ${OUT_DIR}/user-data.rendered (no ISO without genisoimage)"
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -output "$ISO" -volid cidata -joliet -rock \
    "${TMP}/user-data" "${TMP}/meta-data" "${TMP}/network-config" >/dev/null
  log "Wrote ${ISO}"
else
  die "genisoimage not found; install genisoimage or use DRY_RUN=1"
fi
