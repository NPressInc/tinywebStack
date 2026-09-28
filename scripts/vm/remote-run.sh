#!/usr/bin/env bash
# Copy tinywebStack scripts to a VM and run a command as root via SSH.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
load_config

usage() {
  echo "Usage: remote-run.sh SSH_TARGET SCRIPT_BASENAME [args...]"
  echo "Example: remote-run.sh twsadmin@192.168.122.45 yunohost-bootstrap.sh family-a.family.test family-a"
  exit 1
}

[[ $# -ge 2 ]] || usage

SSH_TARGET=$1
SCRIPT=$2
shift 2

require_cmd rsync ssh

REMOTE_ROOT="/opt/tinywebstack"
PROVISION_USER="${PROVISION_SSH_USER:-twsadmin}"

if dry_run_is_active; then
  log "DRY_RUN: rsync scripts to ${SSH_TARGET}:${REMOTE_ROOT}"
  log "DRY_RUN: ssh ${SSH_TARGET} sudo bash ${REMOTE_ROOT}/vm/${SCRIPT} $*"
  exit 0
fi

rsync -az \
  "${TW_STACK_ROOT}/scripts/" \
  "${TW_STACK_ROOT}/config/defaults.env" \
  "${SSH_TARGET}:~/tinywebstack-staging/"

LAB_DIR="${TW_STACK_LAB_CA_DIR:-${TW_STACK_SECRETS_DIR}/lab-ca}"
if [[ -d "${LAB_DIR}/certs" ]]; then
  rsync -az "${LAB_DIR}/certs/" "${SSH_TARGET}:~/tinywebstack-staging/lab-certs/"
fi
if [[ -f "${LAB_DIR}/lab-ca.crt.pem" ]]; then
  rsync -az "${LAB_DIR}/lab-ca.crt.pem" "${SSH_TARGET}:~/tinywebstack-staging/lab-certs/lab-ca.crt.pem"
fi

ssh -o BatchMode=yes "$SSH_TARGET" bash -s -- "$REMOTE_ROOT" "$SCRIPT" "$PROVISION_USER" "$@" <<'EOF'
set -euo pipefail
REMOTE_ROOT=$1
SCRIPT=$2
PROVISION_USER=$3
shift 3
sudo mkdir -p "${REMOTE_ROOT}"
sudo rsync -a ~/tinywebstack-staging/ "${REMOTE_ROOT}/"
sudo install -m 644 ~/tinywebstack-staging/defaults.env "${REMOTE_ROOT}/defaults.env"
if [[ -d ~/tinywebstack-staging/lab-certs ]]; then
  sudo mkdir -p "${REMOTE_ROOT}/lab-certs"
  sudo rsync -a ~/tinywebstack-staging/lab-certs/ "${REMOTE_ROOT}/lab-certs/"
fi
sudo TW_STACK_ROOT="${REMOTE_ROOT}" bash "${REMOTE_ROOT}/vm/${SCRIPT}" "$@"
if id "${PROVISION_USER}" >/dev/null 2>&1 && command -v yunohost >/dev/null 2>&1; then
  sudo yunohost group adduser admins "${PROVISION_USER}" 2>/dev/null || true
fi
EOF
