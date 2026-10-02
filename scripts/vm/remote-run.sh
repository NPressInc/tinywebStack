#!/usr/bin/env bash
# Copy tinywebStack scripts to a VM and run a command as root via SSH.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${TW_STACK_ROOT}/scripts/lib/secrets.sh"
# shellcheck source=scripts/lib/family_users.sh
source "${TW_STACK_ROOT}/scripts/lib/family_users.sh"
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
  if [[ -f "${TW_STACK_ROOT}/config/nodes.conf" ]]; then
    log "DRY_RUN: rsync config/nodes.conf to ${SSH_TARGET}:${REMOTE_ROOT}/config/nodes.conf"
  fi
  _stdin_note=""
  if [[ -t 0 ]]; then
    _stdin_note=" (ssh -n; no stdin)"
  else
    _stdin_note=" (forward stdin to vm/${SCRIPT})"
  fi
  log "DRY_RUN: ssh ${SSH_TARGET} bash ~/tinywebstack-staging/vm/remote-run-on-node.sh ${REMOTE_ROOT} ${SCRIPT} ${SCRIPT_ARGS[*]:-}${_stdin_note}"
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
    [[ -n "$pw" ]] && printf 'MOBILIZON_ADMIN_PASSWORD=%q\n' "$pw"
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
    # Custom-named participants (TWS_ALICE_USER etc. and the TWS_FAMILY_USERS
    # list from local.env): forward <USER>_PASSWORD so user_test_password
    # resolves them on the VM too. Classic names are already exported above
    # and are skipped here.
    for _tu in "${TWS_ALICE_USER:-alice}" "${TWS_BOB_USER:-bob}" \
               "${TWS_PARENT_USER:-parent}" "${TWS_KID_USER:-kid}"; do
      case "$_tu" in alice|bob|parent|kid) continue ;; esac
      _tpw="$(user_test_password "$NODE_NAME" "$_tu")"
      [[ -n "$_tpw" ]] && printf '%s=%q\n' "$(test_password_env_key "$_tu")" "$_tpw"
    done
    # shellcheck disable=SC2119  # no CLI --users here; env/default resolution only
    for _tu in $(resolve_family_users | tr ',' ' '); do
      case "$_tu" in alice|bob|parent|kid) continue ;; esac
      _tpw="$(user_test_password "$NODE_NAME" "$_tu")"
      [[ -n "$_tpw" ]] && printf '%s=%q\n' "$(test_password_env_key "$_tu")" "$_tpw"
    done
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
rsync -az \
  "${TW_STACK_ROOT}/brand/" \
  "${SSH_TARGET}:~/tinywebstack-staging/brand/"
if [[ -f "${TW_STACK_ROOT}/config/nodes.conf" ]]; then
  ssh "${_ssh_opts[@]}" -n "$SSH_TARGET" "mkdir -p ~/tinywebstack-staging/config"
  rsync -az "${TW_STACK_ROOT}/config/nodes.conf" \
    "${SSH_TARGET}:~/tinywebstack-staging/config/nodes.conf"
fi
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

SSH_STDIN_FLAGS=()
if [[ -t 0 ]]; then
  SSH_STDIN_FLAGS=(-n)
fi

# shellcheck disable=SC2029
ssh "${_ssh_opts[@]}" "${SSH_STDIN_FLAGS[@]}" "$SSH_TARGET" \
  env LC_ALL=C.UTF-8 LANG=C.UTF-8 \
  bash ~/tinywebstack-staging/vm/remote-run-on-node.sh \
  "$REMOTE_ROOT" "$SCRIPT" "${SCRIPT_ARGS[@]}"
