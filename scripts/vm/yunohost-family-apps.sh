#!/usr/bin/env bash
# Install Synapse, Element, and location app on a YunoHost test node (idempotent).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
# shellcheck source=scripts/lib/owntracks_ynh_patch.sh
source "${TW_STACK_ROOT}/lib/owntracks_ynh_patch.sh"
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
LOCATION_APP="${LOCATION_APP:-owntracks}"

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
  if ! yunohost app list 2>/dev/null | grep -qw owntracks; then
    _owntracks_stale_removed=()
    for _f in \
      /etc/apt/sources.list.d/owntracks.list \
      /etc/apt/preferences.d/owntracks \
      /etc/apt/trusted.gpg.d/owntracks.gpg
    do
      if [[ -e "$_f" ]]; then
        rm -f "$_f"
        _owntracks_stale_removed+=("$_f")
      fi
    done
    if [[ ${#_owntracks_stale_removed[@]} -gt 0 ]]; then
      log "Removed stale OwnTracks apt artifacts from failed install (owntracks not installed): ${_owntracks_stale_removed[*]}"
    fi
    unset _f _owntracks_stale_removed
  fi
  if [[ -x "${TW_STACK_ROOT}/vm/prep-owntracks-apt.sh" ]]; then
    "${TW_STACK_ROOT}/vm/prep-owntracks-apt.sh" || die "OwnTracks apt prep failed"
  fi
  # init_main_permission is tightened later by family-groups.sh (parents only for web UI).
  OWNTRACKS_ARGS="domain=${LOC_D}&path=/&init_main_permission=all_users"
  OWNTRACKS_INSTALL_SRC="${OWNTRACKS_APP_URL}"
  _owntracks_clone_trap_set=0
  _owntracks_prev_exit_trap=""
  # shellcheck disable=SC2317
  owntracks_ynh_restore_prev_exit_trap() {
    eval "${_owntracks_prev_exit_trap}"
  }
  if ! yunohost app list 2>/dev/null | grep -qw owntracks; then
    _owntracks_prev_exit_trap="$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\\1/" || true)"
    # shellcheck disable=SC2317
    owntracks_ynh_family_exit() {
      owntracks_ynh_cleanup_clone
      if [[ -n "${_owntracks_prev_exit_trap}" ]]; then
        owntracks_ynh_restore_prev_exit_trap
      fi
    }
    trap owntracks_ynh_family_exit EXIT
    _owntracks_clone_trap_set=1
    owntracks_ynh_resolve_install_source "${OWNTRACKS_APP_URL}"
    OWNTRACKS_INSTALL_SRC="${OWNTRACKS_YNH_INSTALL_SRC}"
  fi
  if ! install_app owntracks "${OWNTRACKS_INSTALL_SRC}" --force --args "$OWNTRACKS_ARGS"; then
    log "owntracks_ynh install failed; ensuring ot-recorder via prep fallback"
    "${TW_STACK_ROOT}/vm/prep-owntracks-apt.sh"
    install_app owntracks "${OWNTRACKS_INSTALL_SRC}" --force --args "$OWNTRACKS_ARGS" \
      || die "OwnTracks install failed after apt fallback"
  fi
  if [[ "$_owntracks_clone_trap_set" -eq 1 ]]; then
    owntracks_ynh_cleanup_clone
    if [[ -n "${_owntracks_prev_exit_trap}" ]]; then
      trap owntracks_ynh_restore_prev_exit_trap EXIT
    else
      trap - EXIT
    fi
  fi
else
  TRACCAR_ARGS="domain=${LOC_D}&init_main_permission=all_users"
  install_app traccar traccar --args "$TRACCAR_ARGS"
  if [[ -n "$NODE_NAME" && -x "${TW_STACK_ROOT}/vm/setup-traccar-admin.sh" ]]; then
    "${TW_STACK_ROOT}/vm/setup-traccar-admin.sh" "$MAIN_DOMAIN" "$NODE_NAME"
  fi
fi

if [[ -f "${TW_STACK_ROOT}/vm/install-nextcloud-calendar.sh" ]]; then
  bash "${TW_STACK_ROOT}/vm/install-nextcloud-calendar.sh" "$MAIN_DOMAIN" "$NODE_NAME"
else
  die "Missing ${TW_STACK_ROOT}/vm/install-nextcloud-calendar.sh (Nextcloud calendar install required)"
fi

echo "Apps on ${MAIN_DOMAIN}: Synapse https://${MATRIX_D} | Element https://${ELEMENT_D} | ${LOCATION_APP} https://${LOC_D}"
