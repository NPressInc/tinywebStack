#!/usr/bin/env bash
# Install tinywebstack_family Synapse module into the synapse_ynh venv (idempotent).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

usage() {
  echo "Usage: install-family-module.sh [MAIN_DOMAIN]"
  exit 1
}

MAIN_DOMAIN=${1:-}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

MODULE_SRC="${TW_STACK_ROOT}/family/synapse_module"
[[ -d "$MODULE_SRC" ]] || die "Missing ${MODULE_SRC} (sync family/ to the node)"

find_synapse_pip() {
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

PIP="$(find_synapse_pip)" || die "Could not find Synapse venv pip"

log "Installing tinywebstack-family via ${PIP}"
"$PIP" install -q --upgrade --no-deps -e "$MODULE_SRC"

CONF_D="/etc/matrix-synapse/conf.d"
SNIPPET="${CONF_D}/tinywebstack-family.yaml"
POLICY_PATH="${TWS_POLICY_PATH:-/etc/tinywebstack/family-policy.json}"
mkdir -p /etc/tinywebstack
if [[ ! -f "$POLICY_PATH" ]]; then
  SERVER="${MAIN_DOMAIN:-local.test}"
  cat >"$POLICY_PATH" <<EOF
{
  "server_name": "${SERVER}",
  "parent_mxids": [],
  "trusted_domains": [],
  "reject_encryption": true,
  "kids": {}
}
EOF
  chmod 640 "$POLICY_PATH"
  if getent group synapse >/dev/null 2>&1; then
    chown root:synapse "$POLICY_PATH"
  fi
  log "Created empty policy at ${POLICY_PATH}"
fi

mkdir -p "$CONF_D"
TMP="$(mktemp)"
cat >"$TMP" <<EOF
# Managed by tinywebStack install-family-module.sh
modules:
  - module: tinywebstack_family.module.FamilySpamCheckerModule
    config:
      policy_path: ${POLICY_PATH}
      reject_encryption: true

encryption_enabled_by_default_for_room_type: "off"
EOF

if [[ -f "$SNIPPET" ]] && cmp -s "$TMP" "$SNIPPET"; then
  rm -f "$TMP"
  log "Synapse family snippet unchanged"
else
  mv "$TMP" "$SNIPPET"
  if getent group synapse >/dev/null 2>&1; then
    chown root:synapse "$SNIPPET"
    chmod 640 "$SNIPPET"
  fi
  log "Wrote ${SNIPPET}"
fi

restart_synapse() {
  if systemctl list-unit-files synapse.service >/dev/null 2>&1; then
    systemctl restart synapse
  elif systemctl list-unit-files matrix-synapse.service >/dev/null 2>&1; then
    systemctl restart matrix-synapse
  else
    systemctl restart synapse 2>/dev/null || systemctl restart matrix-synapse
  fi
}

restart_synapse
log "Synapse family module installed"
