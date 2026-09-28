#!/usr/bin/env bash
# Install Synapse, Element, and location app on a YunoHost test node (idempotent).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
load_config

usage() {
  echo "Usage: yunohost-family-apps.sh MAIN_DOMAIN [NODE_NAME]"
  exit 1
}

[[ $# -ge 1 ]] || usage
MAIN_DOMAIN=$1
NODE_NAME=${2:-}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

MATRIX_D="$(matrix_domain "$MAIN_DOMAIN")"
ELEMENT_D="$(element_domain "$MAIN_DOMAIN")"
LOC_D="$(location_domain "$MAIN_DOMAIN")"
LOCATION_APP="${LOCATION_APP:-traccar}"

install_app() {
  local app_id=$1
  shift
  if yunohost app list 2>/dev/null | grep -qw "$app_id"; then
    echo "[tinywebstack] App ${app_id} already installed"
    return 0
  fi
  yunohost app install "$@"
}

SYNAPSE_ARGS="domain=${MATRIX_D}&server_name=${MAIN_DOMAIN}&is_free_registration=0&init_main_permission=all_users"
ELEMENT_ARGS="domain=${ELEMENT_D}&path=/&default_home_server=${MAIN_DOMAIN}&init_main_permission=visitors"

install_app synapse synapse --args "$SYNAPSE_ARGS"
install_app element element --args "$ELEMENT_ARGS"

if [[ "$LOCATION_APP" == "owntracks" ]]; then
  if [[ -x "${TW_STACK_ROOT}/vm/prep-owntracks-apt.sh" ]]; then
    "${TW_STACK_ROOT}/vm/prep-owntracks-apt.sh"
  fi
  OWNTRACKS_ARGS="domain=${LOC_D}&path=/&init_main_permission=all_users"
  install_app owntracks "${OWNTRACKS_APP_URL}" --force --args "$OWNTRACKS_ARGS"
else
  TRACCAR_ARGS="domain=${LOC_D}&init_main_permission=all_users"
  install_app traccar traccar --args "$TRACCAR_ARGS"
  if [[ -n "$NODE_NAME" && -x "${TW_STACK_ROOT}/vm/setup-traccar-admin.sh" ]]; then
    "${TW_STACK_ROOT}/vm/setup-traccar-admin.sh" "$MAIN_DOMAIN" "$NODE_NAME"
  fi
fi

echo "Apps on ${MAIN_DOMAIN}: Synapse https://${MATRIX_D} | Element https://${ELEMENT_D} | ${LOCATION_APP} https://${LOC_D}"
