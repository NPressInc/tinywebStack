#!/usr/bin/env bash
# Run ON the VM (via SSH) after Debian cloud-init: install YunoHost + main domain.
# Idempotent: skips steps that yunohost reports as already done.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: yunohost-bootstrap.sh MAIN_DOMAIN [ADMIN_USER]

Environment:
  YUNOHOST_ADMIN_PASSWORD  If unset, a password is generated and printed once.

Must run as root on the VM.
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
MAIN_DOMAIN=$1
ADMIN_USER=${2:-admin}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if ! command -v yunohost >/dev/null 2>&1; then
  curl -sSf https://install.yunohost.fr | bash
fi

if ! yunohost domain list 2>/dev/null | grep -qF "$MAIN_DOMAIN"; then
  yunohost domain add "$MAIN_DOMAIN"
fi

# Private test DNS: self-signed TLS (Let's Encrypt will not work for non-public names).
if ! yunohost domain cert list 2>/dev/null | grep -qF "$MAIN_DOMAIN"; then
  yunohost domain cert install "$MAIN_DOMAIN" --self-signed
fi

if [[ -z "${YUNOHOST_ADMIN_PASSWORD:-}" ]]; then
  YUNOHOST_ADMIN_PASSWORD="$(openssl rand -base64 24)"
  echo "Generated YunoHost admin password (save this): ${YUNOHOST_ADMIN_PASSWORD}"
fi

if ! yunohost user list 2>/dev/null | grep -qF "${ADMIN_USER}"; then
  yunohost user create "$ADMIN_USER" --firstname Admin --lastname User \
    --password "$YUNOHOST_ADMIN_PASSWORD"
fi

echo "YunoHost bootstrap complete for ${MAIN_DOMAIN}"
