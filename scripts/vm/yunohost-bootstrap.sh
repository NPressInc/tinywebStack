#!/usr/bin/env bash
# Run ON the VM (via SSH) after Debian cloud-init: install YunoHost + postinstall.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${TW_STACK_ROOT}/lib/secrets.sh"
load_config

usage() {
  cat <<'EOF'
Usage: yunohost-bootstrap.sh MAIN_DOMAIN [NODE_NAME]

Environment (preferred over generating new secrets):
  YUNOHOST_ADMIN_PASSWORD   Admin password for postinstall
  TW_STACK_SECRETS_FILE     Key/value file (see docs/test-nodes.md)

Must run as root on the VM.
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
MAIN_DOMAIN=$1
NODE_NAME=${2:-unknown}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

YUNOHOST_ADMIN_USER="${YUNOHOST_ADMIN_USER:-twsadmin}"
YUNOHOST_INSTALL_URL="${YUNOHOST_INSTALL_URL:-https://install.yunohost.org}"

if ! command -v yunohost >/dev/null 2>&1; then
  curl -sSf "${YUNOHOST_INSTALL_URL}" | bash -s -- -a
fi

if [[ ! -f /etc/yunohost/installed ]]; then
  if [[ -z "${YUNOHOST_ADMIN_PASSWORD:-}" ]]; then
    YUNOHOST_ADMIN_PASSWORD="$(read_node_secret "$NODE_NAME" yunohost_admin_password || true)"
  fi
  if [[ -z "${YUNOHOST_ADMIN_PASSWORD:-}" ]]; then
    YUNOHOST_ADMIN_PASSWORD="$(openssl rand -base64 24)"
    if [[ "$NODE_NAME" != "unknown" ]]; then
      write_node_secret "$NODE_NAME" yunohost_admin_password "$YUNOHOST_ADMIN_PASSWORD"
    else
      ensure_secrets_dir
      install -m 600 /dev/null "$(secrets_file)" 2>/dev/null || true
      printf 'YUNOHOST_ADMIN_PASSWORD=%q\n' "$YUNOHOST_ADMIN_PASSWORD" >>"$(secrets_file)"
      chmod 600 "$(secrets_file)"
      log "Generated admin password written to $(secrets_file) (not printed)"
    fi
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

if ! yunohost domain cert list 2>/dev/null | grep -qF "$MAIN_DOMAIN"; then
  yunohost domain cert install "$MAIN_DOMAIN" --self-signed --force || \
    yunohost domain cert install "$MAIN_DOMAIN" --self-signed
fi

# Lab CA cert (preferred for cross-node federation); no-op if not deployed yet.
if [[ -x "${TW_STACK_ROOT}/vm/yunohost-lab-tls.sh" ]]; then
  "${TW_STACK_ROOT}/vm/yunohost-lab-tls.sh" "$MAIN_DOMAIN" || true
fi

log "YunoHost bootstrap complete for ${MAIN_DOMAIN} (admin user: ${YUNOHOST_ADMIN_USER})"
