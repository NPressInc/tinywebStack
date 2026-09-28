#!/usr/bin/env bash
# Install Synapse, Element, and OwnTracks on a YunoHost test node (idempotent).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

OWNTRACKS_APP_URL="${OWNTRACKS_APP_URL:-https://github.com/YunoHost-Apps/owntracks_ynh}"

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

SYNAPSE_ARGS="domain=${MAIN_DOMAIN} server_name= is_free_registration=false init_main_permission=all_users"
ELEMENT_ARGS="domain=${MAIN_DOMAIN} path=/element default_home_server=${MAIN_DOMAIN} init_main_permission=visitors"
OWNTRACKS_ARGS="domain=${MAIN_DOMAIN} path=/owntracks init_main_permission=all_users"

install_app synapse synapse --args "$SYNAPSE_ARGS"
install_app element element --args "$ELEMENT_ARGS"
install_app owntracks "${OWNTRACKS_APP_URL}" --args "$OWNTRACKS_ARGS"

yunohost app change-url element -d "${MAIN_DOMAIN}" -p /element 2>/dev/null || true

echo "Apps installed on ${MAIN_DOMAIN}. Configure permissions via yunohost user permission."
