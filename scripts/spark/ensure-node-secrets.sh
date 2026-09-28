#!/usr/bin/env bash
# Generate missing passwords on spark (source of truth: ~/.tinywebstack-secrets/passwords.env).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${TW_STACK_ROOT}/scripts/lib/secrets.sh"
load_config

gen_if_missing() {
  local node=$1
  local kind=$2
  if [[ -n "$(read_node_secret "$node" "$kind" || true)" ]]; then
    return 0
  fi
  write_node_secret "$node" "$kind" "$(openssl rand -base64 18)"
}

while read -r name domain _rest; do
  [[ -n "$name" ]] || continue
  gen_if_missing "$name" yunohost_admin_password
  gen_if_missing "$name" alice_password
  gen_if_missing "$name" bob_password
  gen_if_missing "$name" traccar_admin_password
  gen_if_missing "$name" parent_password
  gen_if_missing "$name" kid_password
  if [[ -n "$domain" && -z "$(read_node_secret "$name" traccar_admin_login || true)" ]]; then
    write_node_secret "$name" traccar_admin_login "admin@${domain}"
  fi
done < <(read_nodes_conf)

log "Secrets ready in $(secrets_file)"
