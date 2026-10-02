#!/usr/bin/env bash
# Runs on the VM after remote-run.sh rsyncs ~/tinywebstack-staging (stdin must reach vm/*.sh).
set -euo pipefail

REMOTE_ROOT=$1
SCRIPT=$2
shift 2

STAGING="${HOME}/tinywebstack-staging"
sudo mkdir -p "${REMOTE_ROOT}"
sudo rsync -a "${STAGING}/" "${REMOTE_ROOT}/"
sudo install -m 644 "${STAGING}/defaults.env" "${REMOTE_ROOT}/defaults.env"
sudo install -m 600 "${STAGING}/remote.env" "${REMOTE_ROOT}/remote.env"
if [[ -f "${STAGING}/config/nodes.conf" ]]; then
  sudo mkdir -p "${REMOTE_ROOT}/config"
  sudo install -m 644 "${STAGING}/config/nodes.conf" "${REMOTE_ROOT}/config/nodes.conf"
fi
if [[ -d "${STAGING}/lab-certs" ]]; then
  sudo mkdir -p "${REMOTE_ROOT}/lab-certs"
  sudo rsync -a "${STAGING}/lab-certs/" "${REMOTE_ROOT}/lab-certs/"
fi
if [[ -f "${STAGING}/peers.hosts" ]]; then
  sudo install -m 644 "${STAGING}/peers.hosts" "${REMOTE_ROOT}/peers.hosts"
fi

# shellcheck disable=SC2317  # invoked via trap EXIT
cleanup() {
  sudo rm -f "${REMOTE_ROOT}/remote.env"
  rm -f "${STAGING}/remote.env"
}
trap cleanup EXIT

set +e
sudo bash -c 'set -euo pipefail
REMOTE_ROOT=$1
SCRIPT=$2
shift 2
set -a
# shellcheck source=/dev/null
source "${REMOTE_ROOT}/remote.env"
set +a
export TW_STACK_ROOT="${REMOTE_ROOT}" TW_STACK_IS_REMOTE=1
bash "${REMOTE_ROOT}/vm/${SCRIPT}" "$@"
' bash "${REMOTE_ROOT}" "${SCRIPT}" "$@"
status=$?
set -e
exit $status
