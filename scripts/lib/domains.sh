#!/usr/bin/env bash
# DNS / YunoHost domain layout for a family test node.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

matrix_domain() { printf 'matrix.%s' "$1"; }
push_domain() { printf 'push.%s' "$1"; }
element_domain() { printf 'element.%s' "$1"; }
location_domain() { printf '%s.%s' "${LOCATION_APP:-traccar}" "$1"; }
nextcloud_domain() { printf 'nextcloud.%s' "$1"; }

# Family "events" app (Mobilizon on YunoHost catalog).
events_domain() { printf 'mobilizon.%s' "$1"; }

# Optional Jellyfin. Off unless TWS_JELLYFIN is explicitly enabled.
jellyfin_domain() { printf 'jellyfin.%s' "$1"; }

jellyfin_requested() {
  case "${TWS_JELLYFIN:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# All HTTPS names that must resolve to the VM (main + app subdomains).
node_all_domains() {
  local main=$1
  printf '%s\n' "$main" "$(matrix_domain "$main")" "$(element_domain "$main")" "$(location_domain "$main")" "$(nextcloud_domain "$main")"
  if [[ "${TWS_PUSH_ENABLE:-1}" != "0" ]]; then
    printf '%s\n' "$(push_domain "$main")"
  fi
  if [[ "${EVENTS_APP:-mobilizon}" == "mobilizon" ]]; then
    printf '%s\n' "$(events_domain "$main")"
  fi
  if jellyfin_requested; then
    printf '%s\n' "$(jellyfin_domain "$main")"
  fi
}
