#!/usr/bin/env bash
# DNS / YunoHost domain layout for a family test node.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

matrix_domain() { printf 'matrix.%s' "$1"; }
element_domain() { printf 'element.%s' "$1"; }
location_domain() { printf '%s.%s' "${LOCATION_APP:-traccar}" "$1"; }
nextcloud_domain() { printf 'nextcloud.%s' "$1"; }

# All HTTPS names that must resolve to the VM (main + app subdomains).
node_all_domains() {
  local main=$1
  printf '%s\n' "$main" "$(matrix_domain "$main")" "$(element_domain "$main")" "$(location_domain "$main")" "$(nextcloud_domain "$main")"
}
