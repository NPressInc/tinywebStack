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
# shellcheck source=scripts/lib/remote-node.sh
source "${TW_STACK_ROOT}/scripts/lib/remote-node.sh"
load_config
load_secrets

usage() {
  cat <<'EOF'
Usage: remote-run.sh [user@]host SCRIPT_BASENAME [args...]

Uses REMOTE_SSH_USER (default root) when host is given without a user.
Secrets and safe config values are passed via a root-only env file on the VM.
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage

SSH_TARGET=$1
SCRIPT=$2
shift 2
SCRIPT_ARGS=("$@")

if [[ "$SSH_TARGET" != *@* ]]; then
  SSH_TARGET="${REMOTE_SSH_USER:-root}@${SSH_TARGET}"
fi

HOST="${SSH_TARGET#*@}"
mapfile -t _ssh_opts < <(spark_ssh_opts)
ensure_ssh_known_host "$HOST"

require_cmd rsync ssh

REMOTE_ROOT="/opt/tinywebstack"
NODE_NAME="$(node_name_from_remote_script "$SCRIPT" "${SCRIPT_ARGS[@]}")"

if dry_run_is_active; then
  log "DRY_RUN: rsync scripts to ${SSH_TARGET}:${REMOTE_ROOT} (node=${NODE_NAME:-none})"
  log "DRY_RUN: ssh ${SSH_TARGET} sudo bash ${REMOTE_ROOT}/vm/${SCRIPT} ${SCRIPT_ARGS[*]:-}"
  exit 0
fi

REMOTE_ENV="$(mktemp)"
{
  if [[ -f "${TW_STACK_ROOT}/config/local.env" ]]; then
    grep -Ev '^(HOME|TW_STACK_SECRETS|TW_STACK_IMAGE|TW_STACK_VM|TW_STACK_SSH|TW_STACK_LAB)=' \
      "${TW_STACK_ROOT}/config/local.env" || true
  fi
  if [[ -n "${NODE_NAME:-}" && "$NODE_NAME" != "unknown" ]]; then
    pw="$(read_node_secret "$NODE_NAME" yunohost_admin_password || true)"
    [[ -n "$pw" ]] && printf 'YUNOHOST_ADMIN_PASSWORD=%q\n' "$pw"
    apw="$(read_node_secret "$NODE_NAME" alice_password || true)"
    [[ -n "$apw" ]] && printf 'ALICE_PASSWORD=%q\n' "$apw"
    bpw="$(read_node_secret "$NODE_NAME" bob_password || true)"
    [[ -n "$bpw" ]] && printf 'BOB_PASSWORD=%q\n' "$bpw"
    tpw="$(read_node_secret "$NODE_NAME" traccar_admin_password || true)"
    [[ -n "$tpw" ]] && printf 'TRACCAR_ADMIN_PASSWORD=%q\n' "$tpw"
    ppw="$(read_node_secret "$NODE_NAME" parent_password || true)"
    [[ -n "$ppw" ]] && printf 'PARENT_PASSWORD=%q\n' "$ppw"
    kpw="$(read_node_secret "$NODE_NAME" kid_password || true)"
    [[ -n "$kpw" ]] && printf 'KID_PASSWORD=%q\n' "$kpw"
    tlogin="$(read_node_secret "$NODE_NAME" traccar_admin_login || true)"
    [[ -n "$tlogin" ]] && printf 'TRACCAR_ADMIN_LOGIN=%q\n' "$tlogin"
  fi
  printf 'TW_STACK_SECRETS_SOURCE=spark\nTW_STACK_IS_REMOTE=1\n'
} > "$REMOTE_ENV"

rsync -az \
  "${TW_STACK_ROOT}/scripts/" \
  "${TW_STACK_ROOT}/config/defaults.env" \
  "${SSH_TARGET}:~/tinywebstack-staging/"
rsync -az \
  "${TW_STACK_ROOT}/family/" \
  "${SSH_TARGET}:~/tinywebstack-staging/family/"
rsync -az "$REMOTE_ENV" "${SSH_TARGET}:~/tinywebstack-staging/remote.env"

rm -f "$REMOTE_ENV"

LAB_DIR="${TW_STACK_LAB_CA_DIR:-${TW_STACK_SECRETS_DIR}/lab-ca}"
if [[ -d "${LAB_DIR}/certs" ]]; then
  rsync -az "${LAB_DIR}/certs/" "${SSH_TARGET}:~/tinywebstack-staging/lab-certs/"
fi
if [[ -f "${LAB_DIR}/lab-ca.crt.pem" ]]; then
  rsync -az "${LAB_DIR}/lab-ca.crt.pem" "${SSH_TARGET}:~/tinywebstack-staging/lab-certs/lab-ca.crt.pem"
fi
if [[ -n "${TW_STACK_PEERS_HOSTS_FILE:-}" && -f "${TW_STACK_PEERS_HOSTS_FILE}" ]]; then
  rsync -az "${TW_STACK_PEERS_HOSTS_FILE}" "${SSH_TARGET}:~/tinywebstack-staging/peers.hosts"
elif [[ -n "${NODE_NAME:-}" && -f "${TW_STACK_SECRETS_DIR}/peers.${NODE_NAME}.hosts" ]]; then
  rsync -az "${TW_STACK_SECRETS_DIR}/peers.${NODE_NAME}.hosts" \
    "${SSH_TARGET}:~/tinywebstack-staging/peers.hosts"
fi

# shellcheck disable=SC2086
ssh "${_ssh_opts[@]}" "$SSH_TARGET" \
  env LC_ALL=C.UTF-8 LANG=C.UTF-8 \
  bash -s -- "$REMOTE_ROOT" "$SCRIPT" "${SCRIPT_ARGS[@]}" <<'EOF'
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
if [[ -f ~/tinywebstack-staging/peers.hosts ]]; then
  sudo install -m 644 ~/tinywebstack-staging/peers.hosts "${REMOTE_ROOT}/peers.hosts"
fi
sudo TW_STACK_ROOT="${REMOTE_ROOT}" TW_STACK_IS_REMOTE=1 bash "${REMOTE_ROOT}/vm/${SCRIPT}" "$@"
sudo rm -f "${REMOTE_ROOT}/remote.env"
EOF
