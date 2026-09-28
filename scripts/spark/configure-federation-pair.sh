#!/usr/bin/env bash
# From spark: push allowlists to two nodes so they only federate with each other.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config

usage() {
  cat <<'EOF'
Usage: configure-federation-pair.sh NODE_A_SSH NODE_B_SSH

Example:
  configure-federation-pair.sh twsadmin@10.0.0.11 twsadmin@10.0.0.12

Reads domains from config/nodes.conf (first two nodes).
EOF
  exit 1
}

[[ $# -eq 2 ]] || usage
SSH_A=$1
SSH_B=$2

mapfile -t rows < <(read_nodes_conf)
[[ ${#rows[@]} -ge 2 ]] || die "Need at least two nodes in config/nodes.conf"

read -r _name_a domain_a _rest <<< "${rows[0]}"
read -r _name_b domain_b _rest <<< "${rows[1]}"

"${TW_STACK_ROOT}/scripts/vm/remote-run.sh" "$SSH_A" synapse-federation-allowlist.sh "$domain_a" "$domain_b" || die "Federation config failed on A"
"${TW_STACK_ROOT}/scripts/vm/remote-run.sh" "$SSH_B" synapse-federation-allowlist.sh "$domain_b" "$domain_a" || die "Federation config failed on B"

log "Federation allowlists configured: ${domain_a} <-> ${domain_b}"
