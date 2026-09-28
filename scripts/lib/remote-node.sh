#!/usr/bin/env bash
# Map remote-run script + args → spark node name (for secrets lookup).
set -euo pipefail

node_name_from_remote_script() {
  local script=$1
  shift
  case "$script" in
    yunohost-bootstrap.sh | create-matrix-test-users.sh | setup-traccar-admin.sh | family-init.sh | create-family-test-users.sh | install-mobilizon.sh | mobilizon-federation-sync.sh)
      if [[ $# -ge 2 ]]; then
        printf '%s\n' "$2"
      else
        printf 'unknown\n'
      fi
      ;;
    yunohost-family-apps.sh | install-family-module.sh | install-family-dashboard.sh | mobilizon-family-config.sh)
      if [[ $# -ge 2 ]]; then
        printf '%s\n' "$2"
      elif [[ $# -ge 1 ]]; then
        printf '%s\n' "$1"
      fi
      ;;
    *)
      :
      ;;
  esac
}
