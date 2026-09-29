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

validate_spark_node_name() {
  local node=$1
  local ctx=${2:-secrets lookup}
  if [[ "$node" == *.* ]]; then
    die "Invalid node name '${node}' for ${ctx} (looks like a domain). Use the spark node id (e.g. family-a), not family-a.family.test. Example: remote-run.sh \"\$IP\" install-family-dashboard.sh family-a.family.test family-a"
  fi
  if [[ ! "$node" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    die "Invalid node name '${node}' for ${ctx} (use letters, digits, hyphen, underscore; e.g. family-a)"
  fi
}

secret_key_for_node() {
  local node=$1
  local kind=${2:-yunohost_admin_password}
  validate_spark_node_name "$node"
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

# Password for spark-generated test node secrets (see ensure-node-secrets.sh).
generate_test_password() {
  if [[ -n "${LAB_PASSWORD:-}" ]]; then
    if [[ ${#LAB_PASSWORD} -lt 8 ]]; then
      log "WARN: LAB_PASSWORD is under 8 characters; YunoHost may reject user/admin passwords"
    fi
    printf '%s' "$LAB_PASSWORD"
    return 0
  fi
  openssl rand -base64 18
}

write_node_secret() {
  local node=$1
  local kind=$2
  local value=$3
  local key f tmp
  if [[ "${TW_STACK_IS_REMOTE:-0}" == "1" || "${DRY_RUN:-0}" == "1" ]]; then
    log "Skip writing secret ${kind} for ${node} (remote or DRY_RUN)"
    return 0
  fi
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
