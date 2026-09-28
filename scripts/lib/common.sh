#!/usr/bin/env bash
# Shared helpers for tinywebStack VM scripts.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { printf '[tinywebstack] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Missing required command: $c"
  done
}

load_config() {
  if [[ -f "${TW_STACK_ROOT}/config/defaults.env" ]]; then
    # shellcheck source=/dev/null
    source "${TW_STACK_ROOT}/config/defaults.env"
  fi
  if [[ -f "${TW_STACK_ROOT}/config/local.env" ]]; then
    # shellcheck source=/dev/null
    source "${TW_STACK_ROOT}/config/local.env"
  fi
}

vm_domain_name() {
  printf 'tws-%s' "$1"
}

vm_disk_path() {
  printf '%s/%s.qcow2' "${TW_STACK_VM_DIR}" "$(vm_domain_name "$1")"
}

dry_run_is_active() {
  [[ "${DRY_RUN:-0}" == "1" ]]
}

run_or_echo() {
  if dry_run_is_active; then
    log "DRY_RUN: $*"
  else
    log "RUN: $*"
    "$@"
  fi
}

ensure_dir() {
  local d=$1
  if dry_run_is_active; then
    log "DRY_RUN: mkdir -p ${d}"
  fi
  mkdir -p "$d"
}

read_nodes_conf() {
  local conf="${TW_STACK_ROOT}/config/nodes.conf"
  [[ -f "$conf" ]] || die "Missing ${conf} — copy from config/nodes.conf.example"
  grep -Ev '^[[:space:]]*(#|$)' "$conf"
}
