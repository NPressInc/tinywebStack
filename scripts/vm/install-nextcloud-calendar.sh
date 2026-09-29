#!/usr/bin/env bash
# Install YunoHost Nextcloud + Calendar app (idempotent). SSO/LDAP via catalog package.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
# shellcheck source=scripts/lib/yunohost-helper.sh
source "${TW_STACK_ROOT}/lib/yunohost-helper.sh"
# shellcheck source=scripts/lib/nextcloud-occ.sh
source "${TW_STACK_ROOT}/lib/nextcloud-occ.sh"
load_config

usage() {
  echo "Usage: install-nextcloud-calendar.sh MAIN_DOMAIN [NODE_NAME]"
  exit 1
}

[[ $# -ge 1 ]] || usage
MAIN_DOMAIN=$1
# shellcheck disable=SC2034
NODE_NAME=${2:-}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

YUNOHOST_ADMIN_USER="${YUNOHOST_ADMIN_USER:-twsowner}"
NC_DOMAIN="$(nextcloud_domain "$MAIN_DOMAIN")"
NC_PATH="${TWS_NEXTCLOUD_PATH:-/nextcloud}"

if ! yunohost_domain_exists "$NC_DOMAIN"; then
  yunohost domain add "$NC_DOMAIN"
fi

if [[ -f "${TW_STACK_ROOT}/lab-certs/${NC_DOMAIN}/fullchain.pem" ]]; then
  "${TW_STACK_ROOT}/vm/yunohost-lab-tls.sh" "$NC_DOMAIN" || true
elif ! yunohost_domain_has_cert "$NC_DOMAIN"; then
  yunohost domain cert install "$NC_DOMAIN" --self-signed 2>/dev/null || \
    yunohost domain cert install "$NC_DOMAIN" --self-signed || true
fi

install_app() {
  if yunohost app list 2>/dev/null | grep -qw nextcloud; then
    log "[tinywebstack] App nextcloud already installed"
    return 0
  fi
  # visitors: nginx allows CalDAV without portal SSO cookie; Nextcloud handles Basic auth.
  local args="domain=${NC_DOMAIN}&path=${NC_PATH}&admin=${YUNOHOST_ADMIN_USER}&init_main_permission=visitors&user_home=0"
  yunohost app install nextcloud --args "$args"
}

install_app

if yunohost app list 2>/dev/null | grep -qw nextcloud; then
  yunohost user permission add nextcloud.main visitors 2>/dev/null || true
fi

if ! run_nextcloud_occ app:enable calendar; then
  die "Failed to enable Nextcloud Calendar app"
fi

log "Nextcloud Calendar ready at https://${NC_DOMAIN}${NC_PATH} (CalDAV under .../remote.php/dav)"
