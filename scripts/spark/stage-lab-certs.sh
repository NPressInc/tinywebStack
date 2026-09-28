#!/usr/bin/env bash
# Issue lab CA certs for all nodes in config/nodes.conf (run on spark before bootstrap).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/scripts/lib/domains.sh"
load_config

"${TW_STACK_ROOT}/scripts/lab-ca/init-lab-ca.sh"

while read -r name domain _rest; do
  [[ -n "$name" ]] || continue
  while read -r d; do
    [[ -n "$d" ]] || continue
    "${TW_STACK_ROOT}/scripts/lab-ca/issue-domain-cert.sh" "$d"
  done < <(node_all_domains "$domain")
done < <(read_nodes_conf)

log "Lab certs staged under ${TW_STACK_LAB_CA_DIR}/certs/"
