#!/usr/bin/env bash
# Resolve Mobilizon admin API password for root-only federation sync (never echo).
set -euo pipefail

MOBILIZON_ADMIN_PASSWORD_FILE="${MOBILIZON_ADMIN_PASSWORD_FILE:-/etc/tinywebstack/secrets/mobilizon-admin.password}"

read_mobilizon_admin_password() {
  if [[ -n "${MOBILIZON_ADMIN_PASSWORD:-}" ]]; then
    printf '%s' "$MOBILIZON_ADMIN_PASSWORD"
    return 0
  fi
  if [[ -n "${YUNOHOST_ADMIN_PASSWORD:-}" ]]; then
    printf '%s' "$YUNOHOST_ADMIN_PASSWORD"
    return 0
  fi
  if [[ -f "$MOBILIZON_ADMIN_PASSWORD_FILE" ]]; then
    cat "$MOBILIZON_ADMIN_PASSWORD_FILE"
    return 0
  fi
  if [[ -f /etc/tinywebstack/mobilizon-admin.password ]]; then
    cat /etc/tinywebstack/mobilizon-admin.password
    return 0
  fi
  return 1
}

ensure_mobilizon_admin_password_file() {
  local pw=$1
  [[ -n "$pw" ]] || return 1
  # shellcheck source=scripts/lib/tws_state_dir.sh
  _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  source "${_lib}/tws_state_dir.sh"
  ensure_tws_state_dir
  umask 077
  printf '%s' "$pw" >"$MOBILIZON_ADMIN_PASSWORD_FILE"
  tws_state_secret_file "$MOBILIZON_ADMIN_PASSWORD_FILE"
}
