#!/usr/bin/env bash
# Copy tinywebStack scripts to a VM and run a command as root via SSH.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"

usage() {
  echo "Usage: remote-run.sh SSH_TARGET SCRIPT_BASENAME [args...]"
  echo "Example: remote-run.sh admin@192.168.122.45 yunohost-bootstrap.sh family-a.family.test"
  exit 1
}

[[ $# -ge 2 ]] || usage

SSH_TARGET=$1
SCRIPT=$2
shift 2

require_cmd rsync ssh

REMOTE_ROOT="/opt/tinywebstack"

if dry_run_is_active; then
  log "DRY_RUN: rsync scripts to ${SSH_TARGET}:${REMOTE_ROOT}"
  log "DRY_RUN: ssh ${SSH_TARGET} sudo bash ${REMOTE_ROOT}/scripts/vm/${SCRIPT} $*"
  exit 0
fi

rsync -az \
  "${TW_STACK_ROOT}/scripts/" \
  "${TW_STACK_ROOT}/config/defaults.env" \
  "${SSH_TARGET}:~/tinywebstack-staging/"

ssh -o BatchMode=yes "$SSH_TARGET" bash -s -- "$REMOTE_ROOT" "$SCRIPT" "$@" <<'EOF'
set -euo pipefail
REMOTE_ROOT=$1
SCRIPT=$2
shift 2
sudo mkdir -p "${REMOTE_ROOT}"
sudo rsync -a ~/tinywebstack-staging/ "${REMOTE_ROOT}/"
sudo TW_STACK_ROOT="${REMOTE_ROOT}" bash "${REMOTE_ROOT}/vm/${SCRIPT}" "$@"
EOF
