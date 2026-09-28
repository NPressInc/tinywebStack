#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ssh_known_hosts_file() {
  printf '%s\n' "${TW_STACK_SSH_KNOWN_HOSTS:-${TW_STACK_SECRETS_DIR:-${HOME}/.tinywebstack-secrets}/known_hosts}"
}

spark_ssh_opts() {
  local known
  known="$(ssh_known_hosts_file)"
  printf '%s\n' \
    "-o" "BatchMode=yes" \
    "-o" "StrictHostKeyChecking=yes" \
    "-o" "UserKnownHostsFile=${known}" \
    "-o" "LogLevel=ERROR"
}

ensure_ssh_known_host() {
  local host=$1
  local port=${2:-22}
  local known file
  require_cmd ssh-keyscan
  known="$(ssh_known_hosts_file)"
  mkdir -p "$(dirname "$known")"
  touch "$known"
  chmod 600 "$known"
  if grep -q "^\\[${host}\\]:${port} " "$known" 2>/dev/null || grep -q "^${host} " "$known" 2>/dev/null; then
    return 0
  fi
  file="$(mktemp)"
  ssh-keyscan -H -p "$port" "$host" >>"$file" 2>/dev/null || true
  if [[ ! -s "$file" ]]; then
    rm -f "$file"
    die "ssh-keyscan returned no keys for ${host}:${port}"
  fi
  cat "$file" >>"$known"
  rm -f "$file"
  log "Recorded SSH host key for ${host} in ${known}"
}
