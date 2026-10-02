#!/usr/bin/env bash
# Install the tinywebstack-family Synapse module into the synapse_ynh venv
# as a proper pip package (S5.4).
#
# Installs from the repo checkout (family/synapse_module) or, when
# TWS_FAMILY_MODULE_WHEEL points at a prebuilt wheel, from the wheel.
# Idempotent: re-running with unchanged inputs is a no-op except the
# forced package reinstall (cheap, keeps site-packages in sync with the
# synced source). DRY_RUN=1 logs every mutation and touches nothing.
#
# See docs/module-packaging.md. After `yunohost app upgrade synapse` wipes
# the venv, use scripts/vm/family-module-post-upgrade.sh instead of this.
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
# shellcheck source=/dev/null
source "${_tws_lib_dir}/matrix-server.sh"
load_config

usage() {
  echo "Usage: install-family-module.sh [MAIN_DOMAIN]"
  exit 1
}

MAIN_DOMAIN=${1:-}

# Root is required for the real run; DRY_RUN and TWS_ALLOW_NONROOT=1
# (sandbox tests) skip it since nothing is mutated.
if [[ "$(id -u)" -ne 0 ]] && ! dry_run_is_active && [[ "${TWS_ALLOW_NONROOT:-0}" != "1" ]]; then
  echo "Run as root on the YunoHost VM (or use DRY_RUN=1)" >&2
  exit 1
fi

MODULE_SRC="${TW_STACK_ROOT}/family/synapse_module"
PERMS_SRC="${TW_STACK_ROOT}/family/permissions"
[[ -d "$MODULE_SRC" ]] || die "Missing ${MODULE_SRC} (sync family/ to the node)"
[[ -d "$PERMS_SRC/tinywebstack_permissions" ]] || die "Missing ${PERMS_SRC} (sync family/ to the node)"

PERMS_DB="${TWS_PERMISSIONS_DB:-/etc/tinywebstack/permissions.db}"

# Optional prebuilt wheel (built on the control machine, e.g.
# `python -m pip wheel --no-deps -w dist family/synapse_module`).
WHEEL="${TWS_FAMILY_MODULE_WHEEL:-}"
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "TWS_FAMILY_MODULE_WHEEL set but not found: ${WHEEL}"
fi
INSTALL_SOURCE="${WHEEL:-$MODULE_SRC}"

find_synapse_pip() {
  if [[ -n "${TWS_SYNAPSE_PIP:-}" ]]; then
    # shellcheck disable=SC2153  # intentional: honor env even after load_config
    printf '%s\n' "${TWS_SYNAPSE_PIP}"
    return 0
  fi
  local candidates=(
    /var/www/synapse/venv/bin/pip
    /opt/yunohost/matrix-synapse/venv/bin/pip
    /var/www/matrix-synapse/venv/bin/pip
  )
  local p
  for p in "${candidates[@]}"; do
    [[ -x "$p" ]] && echo "$p" && return 0
  done
  if command -v pip3 >/dev/null 2>&1; then
    command -v pip3
    return 0
  fi
  return 1
}

if dry_run_is_active; then
  PIP="${TWS_SYNAPSE_PIP:-/var/www/synapse/venv/bin/pip}"
  log "DRY_RUN: ${PIP} install --upgrade --no-deps --force-reinstall ${INSTALL_SOURCE}"
else
  PIP="$(find_synapse_pip)" || die "Could not find Synapse venv pip"
  log "Installing tinywebstack-family from ${INSTALL_SOURCE} via ${PIP}"
  "$PIP" install -q --upgrade --no-deps --force-reinstall "$INSTALL_SOURCE"
  log "Installing tinywebstack_permissions from ${PERMS_SRC} via ${PIP}"
  "$PIP" install -q --upgrade --no-deps --force-reinstall "$PERMS_SRC"

  # Fail loudly here rather than letting Synapse boot without the module.
  VENV_PY="${PIP%/*}/python"
  [[ -x "$VENV_PY" ]] || VENV_PY="python3"
  "$VENV_PY" - <<'PY' || die "tinywebstack_family not importable from ${PIP%/*} after install"
import tinywebstack_family
import tinywebstack_permissions
assert tinywebstack_family.FamilySpamCheckerModule
assert tinywebstack_permissions.PermissionsDB
PY
fi

# Sandbox/test overrides (defaults are production paths; see
# docs/module-packaging.md — used by the sandboxed tests for
# family-module-post-upgrade.sh and offline dev runs):
#   TWS_SYNAPSE_PIP             path to the Synapse venv pip (else autodetected)
#   TWS_SYNAPSE_CONF_D          conf.d dir for the module snippet
#   TWS_ALLOW_NONROOT=1         skip the root check (sandbox tests only)
#   TWS_SKIP_RESTART=1          skip systemctl restart (sandbox tests only)

POLICY_PATH="${TWS_POLICY_PATH:-/etc/tinywebstack/family-policy.json}"
if dry_run_is_active; then
  log "DRY_RUN: would ensure ${POLICY_PATH} exists (mode 664, group www-data)"
else
  if [[ "$(id -u)" -eq 0 ]] && [[ "${TWS_ALLOW_NONROOT:-0}" != "1" ]]; then
    if ! getent group tws-perms >/dev/null 2>&1; then
      groupadd --system tws-perms
    fi
    install -d -m 750 -o root -g tws-perms /etc/tinywebstack
    if getent group synapse >/dev/null 2>&1; then
      usermod -aG tws-perms synapse || true
    fi
    if getent group www-data >/dev/null 2>&1; then
      usermod -aG tws-perms www-data || true
    fi
  fi
  if [[ ! -f "$POLICY_PATH" ]]; then
    SERVER="${MAIN_DOMAIN:-local.test}"
    mkdir -p "$(dirname "$POLICY_PATH")"
    cat >"$POLICY_PATH" <<EOF
{
  "server_name": "${SERVER}",
  "parent_mxids": [],
  "trusted_domains": [],
  "reject_encryption": true,
  "kids": {}
}
EOF
    log "Created empty policy at ${POLICY_PATH}"
  fi
  if [[ "$(id -u)" -eq 0 ]] && [[ "${TWS_ALLOW_NONROOT:-0}" != "1" ]]; then
    chmod 640 "$POLICY_PATH"
    if getent group tws-perms >/dev/null 2>&1; then
      chown root:tws-perms "$POLICY_PATH" || true
    elif getent group www-data >/dev/null 2>&1; then
      chown root:www-data "$POLICY_PATH" || true
    fi
  else
    chmod 640 "$POLICY_PATH" 2>/dev/null || chmod 664 "$POLICY_PATH"
  fi
fi

CONF_D="${TWS_SYNAPSE_CONF_D:-/etc/matrix-synapse/conf.d}"
SNIPPET="${CONF_D}/tinywebstack-family.yaml"
SNIPPET_CONTENT="# Managed by tinywebStack install-family-module.sh
modules:
  - module: tinywebstack_family.module.FamilySpamCheckerModule
    config:
      policy_path: ${POLICY_PATH}
      permissions_db: ${PERMS_DB}
      reject_encryption: true

encryption_enabled_by_default_for_room_type: \"off\"
"

if dry_run_is_active; then
  if [[ -f "$SNIPPET" ]] && printf '%s' "$SNIPPET_CONTENT" | cmp -s - "$SNIPPET"; then
    log "DRY_RUN: Synapse family snippet unchanged (${SNIPPET})"
  else
    log "DRY_RUN: would write ${SNIPPET}"
  fi
else
  mkdir -p "$CONF_D"
  TMP="$(mktemp)"
  printf '%s' "$SNIPPET_CONTENT" >"$TMP"
  if [[ -f "$SNIPPET" ]] && cmp -s "$TMP" "$SNIPPET"; then
    rm -f "$TMP"
    log "Synapse family snippet unchanged"
  else
    mv "$TMP" "$SNIPPET"
    if [[ "$(id -u)" -eq 0 ]] && getent group synapse >/dev/null 2>&1; then
      chown root:synapse "$SNIPPET"
      chmod 640 "$SNIPPET"
    fi
    log "Wrote ${SNIPPET}"
  fi
fi

if [[ -n "$MAIN_DOMAIN" ]]; then
  MATRIX_HOST="$(matrix_public_host "$MAIN_DOMAIN")"
  DASH_ENV="/etc/tinywebstack/dashboard.env"
  if dry_run_is_active; then
    log "DRY_RUN: would point TWS_MATRIX_SERVER=${MATRIX_HOST} in ${DASH_ENV} (if present)"
  elif [[ -f "$DASH_ENV" ]]; then
    if grep -q '^TWS_MATRIX_SERVER=' "$DASH_ENV"; then
      sed -i "s|^TWS_MATRIX_SERVER=.*|TWS_MATRIX_SERVER=${MATRIX_HOST}|" "$DASH_ENV"
    else
      printf 'TWS_MATRIX_SERVER=%s\n' "$MATRIX_HOST" >>"$DASH_ENV"
    fi
  fi
fi

restart_synapse() {
  if systemctl list-unit-files synapse.service >/dev/null 2>&1; then
    systemctl restart synapse
  elif systemctl list-unit-files matrix-synapse.service >/dev/null 2>&1; then
    systemctl restart matrix-synapse
  else
    systemctl restart synapse || systemctl restart matrix-synapse
  fi
}

if dry_run_is_active; then
  log "DRY_RUN: would restart Synapse"
elif [[ "${TWS_SKIP_RESTART:-0}" == "1" ]]; then
  log "TWS_SKIP_RESTART=1 — skipping Synapse restart (sandbox/tests)"
else
  restart_synapse
fi
log "Synapse family module installed"
