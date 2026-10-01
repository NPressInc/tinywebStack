#!/usr/bin/env bash
# Push the dashboard federation state file (L2.2) to one node and apply it as
# that node's Synapse federation allowlist, via remote-run.sh.
#
# The dashboard owns the state JSON (TWS_FEDERATION_STATE_PATH on the VM,
# /etc/tinywebstack/federation-state.json by default). This spark-side helper
# reads a local copy, base64-encodes it, and runs
# synapse-federation-allowlist.sh --from-state on the target VM.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config

usage() {
  cat <<'EOF'
Usage: sync-federation-peer-hosts.sh NODE_NAME VM_IP_OR_SSH_TARGET STATE_FILE

NODE_NAME         name from config/nodes.conf (used to resolve LOCAL_DOMAIN)
VM_IP_OR_SSH_TARGET  IP or [user@]host for remote-run.sh
STATE_FILE        dashboard federation state JSON on this (spark) host
EOF
  exit 1
}

[[ $# -eq 3 ]] || usage
NODE_NAME=$1
TARGET=$2
STATE_FILE=$3

[[ -f "$STATE_FILE" ]] || die "Missing federation state file: ${STATE_FILE}"

LOCAL_DOMAIN=""
while read -r name domain _rest; do
  [[ -n "$name" ]] || continue
  if [[ "$name" == "$NODE_NAME" ]]; then
    LOCAL_DOMAIN="${domain:-${name}.${TEST_DOMAIN_SUFFIX}}"
    break
  fi
done < <(read_nodes_conf)
[[ -n "$LOCAL_DOMAIN" ]] || die "Node ${NODE_NAME} not found in nodes.conf"

B64="$(base64 < "$STATE_FILE" | tr -d '\n')"
"${TW_STACK_ROOT}/scripts/vm/remote-run.sh" "$TARGET" synapse-federation-allowlist.sh \
  --from-state "$LOCAL_DOMAIN" "base64:${B64}"

log "Federation state applied on ${NODE_NAME} (${LOCAL_DOMAIN}) from ${STATE_FILE}"
