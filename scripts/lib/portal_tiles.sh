#!/usr/bin/env bash
# YunoHost 12 portal tile helpers (show_tile uses True/False casing per API).
set -euo pipefail

show_portal_tile() {
  local perm=$1
  shift
  yunohost user permission update "$perm" --show_tile True "$@" 2>/dev/null || true
}

hide_portal_tile() {
  local perm=$1
  yunohost user permission update "$perm" --show_tile False 2>/dev/null || true
}
