#!/usr/bin/env bash
# One-time / idempotent seed of federation-state.json from policy + Synapse snippet (L2.2).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/tws_state_dir.sh
source "${TW_STACK_ROOT}/lib/tws_state_dir.sh"
load_config

[[ $# -ge 1 ]] || { echo "Usage: family-federation-state-seed.sh MAIN_DOMAIN" >&2; exit 1; }
MAIN_DOMAIN=$1

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

ensure_tws_state_dir

POLICY="${TWS_POLICY_PATH:-/etc/tinywebstack/family-policy.json}"
STATE="${TWS_FEDERATION_STATE_PATH:-/etc/tinywebstack/federation-state.json}"
SNIPPET="${TWS_SYNAPSE_FED_SNIPPET:-/etc/matrix-synapse/conf.d/tinywebstack-federation.yaml}"

DASH_PY="${TWS_DASHBOARD_PYTHON:-/opt/tinywebstack-family-dashboard/venv/bin/python}"
if [[ ! -x "$DASH_PY" ]]; then
  die "Dashboard venv python not found at ${DASH_PY} (run install-family-dashboard.sh first)"
fi

export POLICY STATE SNIPPET MAIN_DOMAIN TW_STACK_ROOT
"$DASH_PY" - <<'PY'
import os
import sys
from pathlib import Path

dash_root = Path("/opt/tinywebstack-family-dashboard")
for p in (dash_root, Path(os.environ["TW_STACK_ROOT"]) / "family" / "dashboard"):
    if (p / "tinywebstack_dashboard").is_dir():
        sys.path.insert(0, str(p))
        break

from tinywebstack_dashboard.federation import reconcile_state_with_policy

merged = reconcile_state_with_policy(
    Path(os.environ["STATE"]),
    Path(os.environ["POLICY"]),
    server_name=os.environ["MAIN_DOMAIN"],
    synapse_snippet_path=Path(os.environ["SNIPPET"]),
    include_synapse_snippet=True,
)
print(f"Federation state at {os.environ['STATE']}: {merged}")
PY

tws_state_shared_file "$STATE"
log "Federation state reconciled for ${MAIN_DOMAIN}"
