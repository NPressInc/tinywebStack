#!/usr/bin/env bash
# Generate missing passwords on spark (source of truth: ~/.tinywebstack-secrets/passwords.env).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${TW_STACK_ROOT}/scripts/lib/secrets.sh"
# shellcheck source=scripts/lib/family_users.sh
source "${TW_STACK_ROOT}/scripts/lib/family_users.sh"
load_config

gen_if_missing() {
  local node=$1
  local kind=$2
  if [[ -n "$(read_node_secret "$node" "$kind" || true)" ]]; then
    return 0
  fi
  write_node_secret "$node" "$kind" "$(generate_test_password)"
}

while read -r name domain _rest; do
  [[ -n "$name" ]] || continue
  gen_if_missing "$name" yunohost_admin_password
  gen_if_missing "$name" "${TWS_ALICE_USER:-alice}_password"
  gen_if_missing "$name" "${TWS_BOB_USER:-bob}_password"
  gen_if_missing "$name" traccar_admin_password
  gen_if_missing "$name" "${TWS_PARENT_USER:-parent}_password"
  gen_if_missing "$name" "${TWS_KID_USER:-kid}_password"
  # Custom households (scripts/lib/family_users.sh): make sure every family
  # member has a <user>_password secret too (lab parent/kid already covered).
  # shellcheck disable=SC2119  # no CLI --users here; env/default resolution only
  for _fu in $(resolve_family_users | tr ',' ' '); do
    case "$_fu" in alice|bob|parent|kid) continue ;; esac
    gen_if_missing "$name" "${_fu}_password"
  done
  if [[ -n "$domain" && -z "$(read_node_secret "$name" traccar_admin_login || true)" ]]; then
    write_node_secret "$name" traccar_admin_login "admin@${domain}"
  fi
done < <(read_nodes_conf)

log "Secrets ready in $(secrets_file)"
