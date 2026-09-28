#!/usr/bin/env bash
# Install Synapse, Element, and OwnTracks on a YunoHost test node (idempotent).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
if [[ -f "${TW_STACK_ROOT}/lib/common.sh" ]]; then
  source "${TW_STACK_ROOT}/lib/common.sh"
  load_config
else
  OWNTRACKS_APP_URL="${OWNTRACKS_APP_URL:-https://github.com/YunoHost-Apps/owntracks_ynh}"
fi

usage() {
  echo "Usage: yunohost-family-apps.sh MAIN_DOMAIN"
  exit 1
}

[[ $# -ge 1 ]] || usage
MAIN_DOMAIN=$1

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

install_app() {
  local app_id=$1
  shift
  if yunohost app list 2>/dev/null | grep -qw "$app_id"; then
    echo "[tinywebstack] App ${app_id} already installed"
    return 0
  fi
  yunohost app install "$@"
}

# Catalog apps (stable IDs in YunoHost)
install_app synapse synapse
install_app element element
install_app owntracks "${OWNTRACKS_APP_URL}"

# Ensure Element points at local Synapse (YunoHost usually wires this via SSOWAT).
yunohost app change-url element "/element" || true

echo "Apps installed on ${MAIN_DOMAIN}. Configure permissions via yunohost user permission."
