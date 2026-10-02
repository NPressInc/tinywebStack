#!/usr/bin/env bash
# Store Mobilizon admin API password for root-only federation sync (stdin, not argv).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/mobilizon_admin_password.sh
source "${TW_STACK_ROOT}/lib/mobilizon_admin_password.sh"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

if [[ -t 0 ]]; then
  die "Pass password on stdin (e.g. remote-run.sh ... store-mobilizon-admin-password.sh <<<\"\$pw\" or read -s pw; printf %s \"\$pw\" | $0)"
fi

pw="$(cat)"
[[ -n "$pw" ]] || die "Empty password on stdin"
ensure_mobilizon_admin_password_file "$pw"
log "Mobilizon admin password stored at ${MOBILIZON_ADMIN_PASSWORD_FILE}"
