#!/usr/bin/env bash
# Orchestrate family layer v1 install on a YunoHost test node.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

usage() {
  cat <<'EOF'
Usage: family-init.sh MAIN_DOMAIN [NODE_NAME] [extra args...]

Extra args (e.g. --users "william,sophie,emma") are forwarded to
create-family-test-users.sh and setup-family-calendars.sh when NODE_NAME is
set. TWS_FAMILY_USERS env works too; default stays the lab pair (parent,kid).
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
MAIN_DOMAIN=$1
shift
NODE_NAME=${1:-}
if [[ $# -gt 0 ]]; then shift; fi
EXTRA_ARGS=("$@")

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

run_vm_script family-groups.sh
if [[ -f "${TW_STACK_ROOT}/vm/install-mobilizon.sh" ]]; then
  run_vm_script install-mobilizon.sh "$MAIN_DOMAIN" "${NODE_NAME:-}"
fi
run_vm_script install-family-module.sh "$MAIN_DOMAIN"
if [[ -f "${TW_STACK_ROOT}/vm/family-permissions-seed.sh" ]]; then
  run_vm_script family-permissions-seed.sh "$MAIN_DOMAIN"
fi
run_vm_script install-family-dashboard.sh "$MAIN_DOMAIN"
if [[ -f "${TW_STACK_ROOT}/vm/family-federation-state-seed.sh" ]]; then
  run_vm_script family-federation-state-seed.sh "$MAIN_DOMAIN"
fi
if [[ -f "${TW_STACK_ROOT}/vm/install-tinyweb-portal-branding.sh" ]]; then
  run_vm_script install-tinyweb-portal-branding.sh "$MAIN_DOMAIN"
fi

if [[ -n "$NODE_NAME" ]]; then
  run_vm_script create-family-test-users.sh "$MAIN_DOMAIN" "$NODE_NAME" "${EXTRA_ARGS[@]}"
  run_vm_script setup-family-calendars.sh "$MAIN_DOMAIN" "$NODE_NAME" "${EXTRA_ARGS[@]}"
  run_vm_script family-groups.sh
fi

log "Family layer init complete for ${MAIN_DOMAIN}"
