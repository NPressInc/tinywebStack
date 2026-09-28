#!/usr/bin/env bash
# Secret file helpers (never print secret values to stdout).
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

secrets_dir() {
  printf '%s\n' "${TW_STACK_SECRETS_DIR:-${HOME}/.tinywebstack-secrets}"
}

secrets_file() {
  printf '%s\n' "${TW_STACK_SECRETS_FILE:-$(secrets_dir)/passwords.env}"
}

ensure_secrets_dir() {
  local d
  d="$(secrets_dir)"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  mkdir -p "$d"
  chmod 700 "$d"
}

# shellcheck disable=SC2034
load_secrets() {
  local f
  f="$(secrets_file)"
  if [[ -f "$f" ]]; then
    # shellcheck source=/dev/null
    source "$f"
  fi
}

secret_key_for_node() {
  local node=$1
  local kind=${2:-yunohost_admin_password}
  printf '%s_%s' "$(echo "$kind" | tr '[:lower:]' '[:upper:]')" "$(echo "$node" | tr '[:lower:]-' '[:upper:]_')"
}

read_node_secret() {
  local node=$1
  local kind=${2:-yunohost_admin_password}
  local key
  key="$(secret_key_for_node "$node" "$kind")"
  load_secrets
  # shellcheck disable=SC2154
  printf '%s\n' "${!key:-}"
}

write_node_secret() {
  local node=$1
  local kind=$2
  local value=$3
  local key f tmp
  key="$(secret_key_for_node "$node" "$kind")"
  ensure_secrets_dir
  f="$(secrets_file)"
  tmp="$(mktemp)"
  if [[ -f "$f" ]]; then
    grep -Ev "^${key}=" "$f" > "$tmp" || true
  fi
  printf '%s=%q\n' "$key" "$value" >> "$tmp"
  install -m 600 "$tmp" "$f"
  rm -f "$tmp"
  log "Stored ${kind} for node ${node} in $(secrets_file)"
}
