#!/usr/bin/env bash
# Resolve Mobilizon admin API password for root-only federation sync (never echo).
set -euo pipefail

MOBILIZON_ADMIN_PASSWORD_FILE="${MOBILIZON_ADMIN_PASSWORD_FILE:-/etc/tinywebstack/mobilizon-admin.password}"

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
    # Root-only file (0400); dashboard sudo helpers run as root.
    cat "$MOBILIZON_ADMIN_PASSWORD_FILE"
    return 0
  fi
  return 1
}

ensure_mobilizon_admin_password_file() {
  local pw=$1
  [[ -n "$pw" ]] || return 1
  install -d -m 750 -o root -g root /etc/tinywebstack
  umask 077
  printf '%s' "$pw" >"$MOBILIZON_ADMIN_PASSWORD_FILE"
  chmod 400 "$MOBILIZON_ADMIN_PASSWORD_FILE"
  chown root:root "$MOBILIZON_ADMIN_PASSWORD_FILE"
}
