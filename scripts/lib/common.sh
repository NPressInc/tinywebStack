#!/usr/bin/env bash
# Shared helpers for tinywebStack VM scripts.
set -euo pipefail

# Preserve TW_STACK_ROOT when sourced from VM deploy tree (/opt/tinywebstack).
if [[ -z "${TW_STACK_ROOT:-}" ]]; then
  _common_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${_common_lib_dir}/../defaults.env" ]]; then
    TW_STACK_ROOT="$(cd "${_common_lib_dir}/.." && pwd)"
  elif [[ -f "${_common_lib_dir}/../../config/defaults.env" ]]; then
    TW_STACK_ROOT="$(cd "${_common_lib_dir}/../.." && pwd)"
  else
    TW_STACK_ROOT="$(cd "${_common_lib_dir}/.." && pwd)"
  fi
  unset _common_lib_dir
fi

log() { printf '[tinywebstack] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Run scripts/vm/*.sh via bash (do not rely on +x in rsync deploy trees).
run_vm_script() {
  local script_name=$1
  shift
  local path="${TW_STACK_ROOT}/vm/${script_name}"
  [[ -f "$path" ]] || die "Missing VM script: ${path}"
  bash "$path" "$@"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Missing required command: $c"
  done
}

load_config() {
  local f
  for f in \
    "${TW_STACK_ROOT}/config/defaults.env" \
    "${TW_STACK_ROOT}/defaults.env" \
    "${TW_STACK_ROOT}/config/local.env" \
    "${TW_STACK_ROOT}/local.env"
  do
    if [[ -f "$f" ]]; then
      # shellcheck source=/dev/null
      source "$f"
    fi
  done
}

host_debian_arch() {
  dpkg --print-architecture 2>/dev/null || uname -m
}

debian_cloud_arch() {
  case "$(host_debian_arch)" in
    amd64) echo amd64 ;;
    arm64) echo arm64 ;;
    armhf) echo armhf ;;
    *)
      die "Unsupported architecture for Debian cloud images: $(host_debian_arch)"
      ;;
  esac
}

ensure_libvirt_system_uri() {
  export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
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
    log "DRY_RUN: would mkdir -p ${d}"
    return 0
  fi
  mkdir -p "$d"
}

read_nodes_conf() {
  local conf="${TW_NODES_CONF:-${TW_STACK_ROOT}/config/nodes.conf}"
  [[ -f "$conf" ]] || die "Missing ${conf} — copy from config/nodes.conf.example"
  grep -Ev '^[[:space:]]*(#|$)' "$conf"
}
