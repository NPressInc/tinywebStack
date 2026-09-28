#!/usr/bin/env bash
# Map remote-run script + args → spark node name (for secrets lookup).
set -euo pipefail

node_name_from_remote_script() {
  local script=$1
  shift
  case "$script" in
    yunohost-bootstrap.sh | create-matrix-test-users.sh | setup-traccar-admin.sh)
      if [[ $# -ge 2 ]]; then
        printf '%s\n' "$2"
      else
        printf 'unknown\n'
      fi
      ;;
    yunohost-family-apps.sh)
      if [[ $# -ge 2 ]]; then
        printf '%s\n' "$2"
      fi
      ;;
    *)
      :
      ;;
  esac
}
