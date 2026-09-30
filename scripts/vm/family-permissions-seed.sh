#!/usr/bin/env bash
# Seed /etc/tinywebstack/permissions.db from the in-repo role YAMLs (F1.3).
# Idempotent: role definitions are re-applied; household users/overrides come
# from family-policy.json when present and are never clobbered on re-runs.
#
# Usage (on the node, as root): family-permissions-seed.sh [MAIN_DOMAIN]
# Env: TWS_PERMISSIONS_DB overrides the DB path (default /etc/tinywebstack/permissions.db)
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

PERMS_SRC="${TW_STACK_ROOT}/family/permissions"
[[ -d "$PERMS_SRC/tinywebstack_permissions" ]] || die "Missing ${PERMS_SRC} (sync family/ to the node)"

POLICY_PATH="${TWS_POLICY_PATH:-/etc/tinywebstack/family-policy.json}"
DB_PATH="${TWS_PERMISSIONS_DB:-/etc/tinywebstack/permissions.db}"
export TWS_PERMISSIONS_DB="$DB_PATH"

MAIN_DOMAIN="${1:-${TWS_SERVER_NAME:-}}"

export PYTHONPATH="${PERMS_SRC}:${TW_STACK_ROOT}/family/synapse_module${PYTHONPATH:+:${PYTHONPATH}}"

SEED_ARGS=(seed --db "$DB_PATH")
if [[ -f "$POLICY_PATH" ]]; then
  SEED_ARGS+=(--policy "$POLICY_PATH")
fi

if ! python3 -m tinywebstack_permissions.seed_cli "${SEED_ARGS[@]}"; then
  die "permissions DB seed failed (${DB_PATH})"
fi

if [[ -n "$MAIN_DOMAIN" ]]; then
  # Stamp server_name for dashboard/permission lookups (idempotent meta write).
  python3 - "$DB_PATH" "$MAIN_DOMAIN" <<'PY'
import sys
from tinywebstack_permissions.store import PermissionsDB

db_path, server = sys.argv[1], sys.argv[2]
with PermissionsDB(db_path) as db:
    if db.server_name != server:
        db.set_server_name(server)
        print(f"server_name set to {server}")
PY
fi

install -d -m 775 -o root -g www-data /etc/tinywebstack
if [[ -f "$DB_PATH" ]]; then
  chown root:www-data "$DB_PATH"
  chmod 664 "$DB_PATH"
  if getent group synapse >/dev/null 2>&1; then
    usermod -aG www-data synapse || true
  fi
fi

# Keep YunoHost/Mobilizon enforcement aligned with the (now authoritative) store:
# refresh per-kid Mobilizon permissions through the same DB.
APPLY_PY="${TW_STACK_ROOT}/lib/apply_mobilizon_permissions.py"
if [[ -f "$APPLY_PY" && -f "$POLICY_PATH" ]]; then
  # shellcheck source=scripts/lib/mobilizon_python_path.sh
  source "${TW_STACK_ROOT}/lib/mobilizon_python_path.sh"
  export_mobilizon_pythonpath
  python3 "$APPLY_PY" \
    --policy "$POLICY_PATH" \
    --permissions-db "$DB_PATH" \
    --kids-group "${TWS_KIDS_GROUP:-kids}" \
    --parents-group "${TWS_PARENTS_GROUP:-parents}" \
    --federation-test-group "${TWS_FEDERATION_TEST_GROUP:-federation-test}" \
    --admin-user "${MOBILIZON_ADMIN_USER:-${YUNOHOST_ADMIN_USER:-twsowner}}" \
    --main-domain "$MAIN_DOMAIN" || log "WARN: Mobilizon permission refresh failed"
fi

log "Permissions DB ready at ${DB_PATH}"
