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
python3 "$PY" --kids-group "${TWS_KIDS_GROUP:-kids}"
log "Mobilizon kid permissions refreshed"
