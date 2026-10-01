#!/usr/bin/env bash
# Re-apply the tinywebstack-family Synapse module after a Synapse app upgrade
# (S5.4). `yunohost app upgrade synapse` recreates the app venv, which silently
# drops the pip-installed tinywebstack_family; the spam-checker rules then stop
# enforcing while everything else looks healthy.
#
# Usage: family-module-post-upgrade.sh [MAIN_DOMAIN]
#   Run after every `yunohost app upgrade synapse` (see docs/module-packaging.md
#   and docs/production-setup.md §9). Detects the wipe by importing
#   tinywebstack_family with the Synapse venv's python; if missing, re-runs
#   install-family-module.sh with the same args. No-op when the module is
#   already present, so it is safe to run anytime (cron, hooks, muscle memory).
#
# Env:
#   TWS_FAMILY_MODULE_VENV      override the Synapse venv dir (sandbox tests)
#   TWS_FAMILY_MODULE_INSTALLER override install-family-module.sh path
#   DRY_RUN=1                   detect only; log the re-install, run nothing
#   TWS_ALLOW_NONROOT=1         skip the root check (sandbox tests)
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib/ is a sibling of vm/ in BOTH layouts (VM tree: /opt/tinywebstack/lib;
# checkout: repo/scripts/lib), so source tools relative to this script.
if [[ -f "${_script_dir}/../lib/common.sh" ]]; then
  _tws_lib_dir="$(cd "${_script_dir}/../lib" && pwd)"
elif [[ -n "${TW_STACK_ROOT:-}" && -f "${TW_STACK_ROOT}/lib/common.sh" ]]; then
  _tws_lib_dir="${TW_STACK_ROOT}/lib"
else
  echo "Cannot locate scripts/lib/common.sh from ${_script_dir}" >&2
  exit 1
fi
# TW_STACK_ROOT: repo root (checkout, for family/ + config/defaults.env) or
# the VM deploy root (/opt/tinywebstack) — prefer an explicit export.
if [[ -z "${TW_STACK_ROOT:-}" ]] && [[ -f "${_tws_lib_dir}/tw_stack_root.sh" ]]; then
  # shellcheck source=/dev/null
  source "${_tws_lib_dir}/tw_stack_root.sh"
  TW_STACK_ROOT="$(tw_stack_root_from_script_dir "$_script_dir" || true)"
fi
: "${TW_STACK_ROOT:=$(cd "${_script_dir}/.." && pwd)}"
# shellcheck source=/dev/null
source "${_tws_lib_dir}/common.sh"
load_config

usage() {
  echo "Usage: family-module-post-upgrade.sh [MAIN_DOMAIN]"
  exit 1
}

MAIN_DOMAIN=${1:-}

if [[ "$(id -u)" -ne 0 ]] && ! dry_run_is_active && [[ "${TWS_ALLOW_NONROOT:-0}" != "1" ]]; then
  echo "Run as root on the YunoHost VM (or use DRY_RUN=1)" >&2
  exit 1
fi

find_synapse_venv() {
  if [[ -n "${TWS_FAMILY_MODULE_VENV:-}" ]]; then
    printf '%s\n' "${TWS_FAMILY_MODULE_VENV}"
    return 0
  fi
  local candidates=(
    /var/www/synapse/venv
    /opt/yunohost/matrix-synapse/venv
    /var/www/matrix-synapse/venv
  )
  local v
  for v in "${candidates[@]}"; do
    [[ -x "${v}/bin/python" ]] && echo "$v" && return 0
  done
  return 1
}

VENV="$(find_synapse_venv)" || die "Could not find a Synapse venv (is synapse installed?)"
VENV_PY="${VENV}/bin/python"
[[ -x "$VENV_PY" ]] || die "No python in Synapse venv: ${VENV}"

module_present() {
  "$VENV_PY" - <<'PY' >/dev/null 2>&1
import tinywebstack_family
assert tinywebstack_family.FamilySpamCheckerModule
PY
}

if module_present; then
  log "tinywebstack_family is present in ${VENV} — nothing to do"
  exit 0
fi

log "tinywebstack_family is MISSING from ${VENV} — a Synapse upgrade likely wiped it; re-applying install-family-module.sh"

# The installer always sits next to this script (VM tree vm/, checkout
# scripts/vm/), so default to _script_dir rather than a TW_STACK_ROOT guess.
INSTALLER="${TWS_FAMILY_MODULE_INSTALLER:-${_script_dir}/install-family-module.sh}"
[[ -f "$INSTALLER" ]] || die "Missing installer script: ${INSTALLER}"
run_or_echo bash "$INSTALLER" "$MAIN_DOMAIN"

if ! dry_run_is_active && ! module_present; then
  die "Re-install completed but tinywebstack_family is still not importable from ${VENV}"
fi

log "Synapse family module re-applied"
