#!/usr/bin/env bash
# Resolve repo root and export PYTHONPATH for tinywebstack_family (VM + spark).
set -euo pipefail

mobilizon_repo_root() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -d "${lib_dir}/../family/synapse_module" ]]; then
    cd "${lib_dir}/.." && pwd
    return 0
  fi
  if [[ -d "${lib_dir}/../../family/synapse_module" ]]; then
    cd "${lib_dir}/../.." && pwd
    return 0
  fi
  if [[ -n "${TW_STACK_ROOT:-}" && -d "${TW_STACK_ROOT}/family/synapse_module" ]]; then
    printf '%s\n' "${TW_STACK_ROOT}"
    return 0
  fi
  echo "Cannot locate family/synapse_module from ${lib_dir}" >&2
  return 1
}

export_mobilizon_pythonpath() {
  local root
  root="$(mobilizon_repo_root)"
  export TW_STACK_ROOT="${TW_STACK_ROOT:-$root}"
  export PYTHONPATH="${root}/family/synapse_module${PYTHONPATH:+:${PYTHONPATH}}"
}
