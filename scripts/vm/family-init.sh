#!/usr/bin/env bash
# Orchestrate family layer v1 install on a YunoHost test node.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

usage() {
  echo "Usage: family-init.sh MAIN_DOMAIN [NODE_NAME]"
  exit 1
}

[[ $# -ge 1 ]] || usage
MAIN_DOMAIN=$1
NODE_NAME=${2:-}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

run_vm_script family-groups.sh
if [[ -f "${TW_STACK_ROOT}/vm/install-mobilizon.sh" ]]; then
  run_vm_script install-mobilizon.sh "$MAIN_DOMAIN" "${NODE_NAME:-}"
fi
run_vm_script install-family-module.sh "$MAIN_DOMAIN"
run_vm_script install-family-dashboard.sh "$MAIN_DOMAIN"
if [[ -f "${TW_STACK_ROOT}/vm/install-tinyweb-portal-branding.sh" ]]; then
  run_vm_script install-tinyweb-portal-branding.sh "$MAIN_DOMAIN"
fi

if [[ -n "$NODE_NAME" ]]; then
  run_vm_script create-family-test-users.sh "$MAIN_DOMAIN" "$NODE_NAME"
  run_vm_script setup-family-calendars.sh "$MAIN_DOMAIN" "$NODE_NAME"
  run_vm_script family-groups.sh
fi

log "Family layer init complete for ${MAIN_DOMAIN}"
