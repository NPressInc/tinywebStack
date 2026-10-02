#!/usr/bin/env bash
# Consistent ownership/modes for /etc/tinywebstack (dashboard writes, Synapse reads).
set -euo pipefail

TWS_STATE_DIR="${TWS_STATE_DIR:-/etc/tinywebstack}"
TWS_STATE_GROUP="${TWS_STATE_GROUP:-tws-perms}"
TWS_STATE_SECRETS_DIR="${TWS_STATE_DIR}/secrets"

ensure_tws_state_group() {
  if [[ "${TWS_ALLOW_NONROOT:-0}" == "1" ]]; then
    return 0
  fi
  if ! getent group "$TWS_STATE_GROUP" >/dev/null 2>&1; then
    groupadd --system "$TWS_STATE_GROUP"
  fi
  if getent group synapse >/dev/null 2>&1; then
    usermod -aG "$TWS_STATE_GROUP" synapse 2>/dev/null || true
  fi
  if getent group www-data >/dev/null 2>&1; then
    usermod -aG "$TWS_STATE_GROUP" www-data 2>/dev/null || true
  fi
}

ensure_tws_state_dir() {
  if [[ "${TWS_ALLOW_NONROOT:-0}" == "1" ]]; then
    mkdir -p "$TWS_STATE_DIR"
    return 0
  fi
  ensure_tws_state_group
  install -d -m 2770 -o root -g "$TWS_STATE_GROUP" "$TWS_STATE_DIR"
  install -d -m 700 -o root -g root "$TWS_STATE_SECRETS_DIR"
}

tws_state_shared_file() {
  local f=$1
  [[ -e "$f" ]] || return 0
  if [[ "${TWS_ALLOW_NONROOT:-0}" == "1" ]]; then
    chmod 660 "$f" 2>/dev/null || true
    return 0
  fi
  chown root:"$TWS_STATE_GROUP" "$f" 2>/dev/null || true
  chmod 660 "$f" 2>/dev/null || true
}

tws_state_secret_file() {
  local f=$1
  [[ -e "$f" ]] || return 0
  chown root:root "$f" 2>/dev/null || true
  chmod 400 "$f" 2>/dev/null || true
}
