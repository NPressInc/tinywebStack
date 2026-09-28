#!/usr/bin/env bash
# Run ON the VM (via SSH) after Debian cloud-init: install YunoHost + postinstall.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${TW_STACK_ROOT}/lib/secrets.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
load_config

usage() {
  cat <<'EOF'
Usage: yunohost-bootstrap.sh MAIN_DOMAIN [NODE_NAME]

Environment (from spark remote.env / TW_STACK_SECRETS_FILE on spark):
  YUNOHOST_ADMIN_PASSWORD

Must run as root on the VM.
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
MAIN_DOMAIN=$1
# shellcheck disable=SC2034
NODE_NAME=${2:-unknown}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

YUNOHOST_ADMIN_USER="${YUNOHOST_ADMIN_USER:-twsowner}"
YUNOHOST_INSTALL_URL="${YUNOHOST_INSTALL_URL:-https://install.yunohost.org}"

if ! command -v yunohost >/dev/null 2>&1; then
  curl -sSf "${YUNOHOST_INSTALL_URL}" | bash -s -- -a
fi

if [[ ! -f /etc/yunohost/installed ]]; then
  if [[ -z "${YUNOHOST_ADMIN_PASSWORD:-}" ]]; then
    die "YUNOHOST_ADMIN_PASSWORD must be set (spark secrets file). Bootstrap does not generate passwords on the VM."
  fi

  yunohost tools postinstall \
    --domain "$MAIN_DOMAIN" \
    --username "$YUNOHOST_ADMIN_USER" \
    --fullname "TinyWebStack Admin" \
    --password "$YUNOHOST_ADMIN_PASSWORD" \
    --ignore-dyndns \
    --force-diskspace \
    --i-have-read-terms-of-services
fi

while read -r d; do
  [[ -n "$d" ]] || continue
  if ! yunohost domain list 2>/dev/null | grep -qF "$d"; then
    yunohost domain add "$d"
  fi
done < <(node_all_domains "$MAIN_DOMAIN")

while read -r d; do
  [[ -n "$d" ]] || continue
  if ! yunohost domain cert list 2>/dev/null | grep -qF "$d"; then
    yunohost domain cert install "$d" --self-signed --force 2>/dev/null || \
      yunohost domain cert install "$d" --self-signed || true
  fi
done < <(node_all_domains "$MAIN_DOMAIN")

if [[ -x "${TW_STACK_ROOT}/vm/yunohost-lab-tls.sh" ]]; then
  while read -r d; do
    [[ -n "$d" ]] || continue
    "${TW_STACK_ROOT}/vm/yunohost-lab-tls.sh" "$d" || true
  done < <(node_all_domains "$MAIN_DOMAIN")
fi

log "YunoHost bootstrap complete for ${MAIN_DOMAIN} node=${NODE_NAME} (admin: ${YUNOHOST_ADMIN_USER})"
