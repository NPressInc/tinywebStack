#!/usr/bin/env bash
# Re-apply Mobilizon SSO permissions after kid policy changes (events_enabled).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/mobilizon_python_path.sh
source "${TW_STACK_ROOT}/lib/mobilizon_python_path.sh"
load_config
export_mobilizon_pythonpath

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

PY="${TW_STACK_ROOT}/lib/apply_mobilizon_permissions.py"
[[ -f "$PY" ]] || die "Missing ${PY}"
MAIN_DOMAIN="${TWS_SERVER_NAME:-}"
if [[ -z "$MAIN_DOMAIN" && -f /etc/tinywebstack/dashboard.env ]]; then
  # shellcheck source=/dev/null
  source /etc/tinywebstack/dashboard.env
  MAIN_DOMAIN="${TWS_SERVER_NAME:-}"
fi
python3 "$PY" \
  --kids-group "${TWS_KIDS_GROUP:-kids}" \
  --parents-group "${TWS_PARENTS_GROUP:-parents}" \
  --federation-test-group "${TWS_FEDERATION_TEST_GROUP:-federation-test}" \
  --admin-user "${MOBILIZON_ADMIN_USER:-${YUNOHOST_ADMIN_USER:-twsowner}}" \
  --main-domain "$MAIN_DOMAIN"
log "Mobilizon kid permissions refreshed"
