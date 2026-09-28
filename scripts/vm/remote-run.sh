#!/usr/bin/env bash
# Copy tinywebStack scripts to a VM and run a command as root via SSH.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${TW_STACK_ROOT}/scripts/lib/secrets.sh"
# shellcheck source=scripts/lib/ssh-spark.sh
source "${TW_STACK_ROOT}/scripts/lib/ssh-spark.sh"
load_config
load_secrets

usage() {
  cat <<'EOF'
Usage: remote-run.sh [user@]host SCRIPT_BASENAME [args...]

Uses REMOTE_SSH_USER (default root) when host is given without a user.
Secrets and config/local.env values are passed via a root-only env file on the VM.
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage

SSH_TARGET=$1
SCRIPT=$2
shift 2

if [[ "$SSH_TARGET" != *@* ]]; then
  SSH_TARGET="${REMOTE_SSH_USER:-root}@${SSH_TARGET}"
fi

HOST="${SSH_TARGET#*@}"
mapfile -t _ssh_opts < <(spark_ssh_opts)
ensure_ssh_known_host "$HOST"

require_cmd rsync ssh

REMOTE_ROOT="/opt/tinywebstack"
NODE_NAME=""
if [[ "$SCRIPT" == "yunohost-bootstrap.sh" || "$SCRIPT" == "yunohost-family-apps.sh" ]]; then
  NODE_NAME="${3:-}"
fi

if dry_run_is_active; then
  log "DRY_RUN: rsync scripts to ${SSH_TARGET}:${REMOTE_ROOT}"
  log "DRY_RUN: ssh ${SSH_TARGET} sudo bash ${REMOTE_ROOT}/vm/${SCRIPT} $*"
  exit 0
fi

REMOTE_ENV="$(mktemp)"
{
  [[ -f "${TW_STACK_ROOT}/config/local.env" ]] && cat "${TW_STACK_ROOT}/config/local.env"
  if [[ -n "$NODE_NAME" ]]; then
    pw="$(read_node_secret "$NODE_NAME" yunohost_admin_password || true)"
    [[ -n "$pw" ]] && printf 'YUNOHOST_ADMIN_PASSWORD=%q\n' "$pw"
    apw="$(read_node_secret "$NODE_NAME" alice_password || true)"
    [[ -n "$apw" ]] && printf 'ALICE_PASSWORD=%q\n' "$apw"
    bpw="$(read_node_secret "$NODE_NAME" bob_password || true)"
    [[ -n "$bpw" ]] && printf 'BOB_PASSWORD=%q\n' "$bpw"
  fi
  printf 'TW_STACK_SECRETS_SOURCE=spark\n'
} > "$REMOTE_ENV"

rsync -az \
  "${TW_STACK_ROOT}/scripts/" \
  "${TW_STACK_ROOT}/config/defaults.env" \
  "${SSH_TARGET}:~/tinywebstack-staging/"
rsync -az "$REMOTE_ENV" "${SSH_TARGET}:~/tinywebstack-staging/remote.env"

rm -f "$REMOTE_ENV"

LAB_DIR="${TW_STACK_LAB_CA_DIR:-${TW_STACK_SECRETS_DIR}/lab-ca}"
if [[ -d "${LAB_DIR}/certs" ]]; then
  rsync -az "${LAB_DIR}/certs/" "${SSH_TARGET}:~/tinywebstack-staging/lab-certs/"
fi
if [[ -f "${LAB_DIR}/lab-ca.crt.pem" ]]; then
  rsync -az "${LAB_DIR}/lab-ca.crt.pem" "${SSH_TARGET}:~/tinywebstack-staging/lab-certs/lab-ca.crt.pem"
fi

# shellcheck disable=SC2086
ssh "${_ssh_opts[@]}" "$SSH_TARGET" \
  env LC_ALL=C.UTF-8 LANG=C.UTF-8 \
  bash -s -- "$REMOTE_ROOT" "$SCRIPT" "$@" <<'EOF'
set -euo pipefail
REMOTE_ROOT=$1
SCRIPT=$2
shift 2
sudo mkdir -p "${REMOTE_ROOT}"
sudo rsync -a ~/tinywebstack-staging/ "${REMOTE_ROOT}/"
sudo install -m 644 ~/tinywebstack-staging/defaults.env "${REMOTE_ROOT}/defaults.env"
sudo install -m 600 ~/tinywebstack-staging/remote.env "${REMOTE_ROOT}/remote.env"
set -a
# shellcheck source=/dev/null
source "${REMOTE_ROOT}/remote.env"
set +a
if [[ -d ~/tinywebstack-staging/lab-certs ]]; then
  sudo mkdir -p "${REMOTE_ROOT}/lab-certs"
  sudo rsync -a ~/tinywebstack-staging/lab-certs/ "${REMOTE_ROOT}/lab-certs/"
fi
sudo TW_STACK_ROOT="${REMOTE_ROOT}" TW_STACK_IS_REMOTE=1 bash "${REMOTE_ROOT}/vm/${SCRIPT}" "$@"
sudo rm -f "${REMOTE_ROOT}/remote.env"
EOF
