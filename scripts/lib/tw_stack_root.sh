#!/usr/bin/env bash
# Resolve repository / deploy root from a script path (spark checkout vs VM tree).
set -euo pipefail

tw_stack_root_from_script_dir() {
  local script_dir=$1
  local git_root=""
  if command -v git >/dev/null 2>&1; then
    git_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  if [[ -n "$git_root" && -f "${git_root}/scripts/lib/common.sh" && -d "${git_root}/family/calendar_module" ]]; then
    printf '%s\n' "$git_root"
    return 0
  fi
  local parent
  parent="$(cd "${script_dir}/.." && pwd)"
  if [[ -f "${parent}/lib/common.sh" && -d "${parent}/family/calendar_module" ]]; then
    printf '%s\n' "$parent"
    return 0
  fi
  local grand
  grand="$(cd "${script_dir}/../.." && pwd)"
  if [[ -f "${grand}/scripts/lib/common.sh" && -d "${grand}/family/calendar_module" ]]; then
    printf '%s\n' "$grand"
    return 0
  fi
  return 1
}
