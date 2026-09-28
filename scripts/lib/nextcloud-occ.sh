#!/usr/bin/env bash
# Resolve Nextcloud occ path + runtime user on a YunoHost node.

nextcloud_occ_path() {
  local candidate
  for candidate in /var/www/nextcloud/occ /var/www/*/occ; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

nextcloud_occ_user() {
  local occ=$1
  stat -c '%U' "$occ" 2>/dev/null || echo nextcloud
}

nextcloud_install_path() {
  local occ=$1
  dirname "$occ"
}

run_nextcloud_occ() {
  local occ user
  occ="$(nextcloud_occ_path)" || return 1
  user="$(nextcloud_occ_user "$occ")"
  sudo -u "$user" php "$occ" "$@"
}
