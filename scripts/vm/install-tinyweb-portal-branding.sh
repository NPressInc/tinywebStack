#!/usr/bin/env bash
# Apply TinyWeb branding to the YunoHost 12 user portal (supported domain config API).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

usage() {
  echo "Usage: install-tinyweb-portal-branding.sh MAIN_DOMAIN"
  exit 1
}

[[ $# -eq 1 ]] || usage
MAIN_DOMAIN=$1

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

BRAND="${TW_STACK_ROOT}/brand/portal"
[[ -d "$BRAND" ]] || die "Missing ${BRAND} (sync repo to the node)"

require_cmd yunohost

LOGO_DST="/usr/share/yunohost/portal/customassets/tinyweb-logo-${MAIN_DOMAIN}.svg"
install -d /usr/share/yunohost/portal/customassets
install -m 644 "${BRAND}/tinyweb-logo.svg" "$LOGO_DST"

USER_INTRO="$(python3 -c "print(open('${BRAND}/user-intro.html').read().replace(chr(10),' ').strip())")"
PUBLIC_INTRO="$(python3 -c "print(open('${BRAND}/public-intro.html').read().replace(chr(10),' ').strip())")"
PORTAL_CSS="$(cat "${BRAND}/tinyweb-portal.css")"

set_portal() {
  yunohost domain config set "$MAIN_DOMAIN" "$1" -v "$2"
}

set_portal feature.portal.portal_title "TinyWeb"
set_portal feature.portal.portal_theme "light"
set_portal feature.portal.enable_public_apps_page "0"
set_portal feature.portal.show_other_domains_apps "0"
set_portal feature.portal.portal_user_intro "$USER_INTRO"
set_portal feature.portal.portal_public_intro "$PUBLIC_INTRO"
set_portal feature.portal.custom_css "$PORTAL_CSS"
set_portal feature.portal.portal_logo "${LOGO_DST}"

if command -v yunohost >/dev/null 2>&1; then
  yunohost app ssowatconf 2>/dev/null || true
fi
log "TinyWeb portal branding applied for ${MAIN_DOMAIN}"
