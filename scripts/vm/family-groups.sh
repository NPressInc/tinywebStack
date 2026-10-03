#!/usr/bin/env bash
# Idempotent parents/kids groups and app permissions for family layer v1.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/portal_tiles.sh
source "${TW_STACK_ROOT}/lib/portal_tiles.sh"
load_config

usage() {
  echo "Usage: family-groups.sh"
  exit 1
}

[[ $# -eq 0 ]] || usage

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

PARENTS_GROUP="${TWS_PARENTS_GROUP:-parents}"
KIDS_GROUP="${TWS_KIDS_GROUP:-kids}"
FED_TEST_GROUP="${TWS_FEDERATION_TEST_GROUP:-federation-test}"
LOCATION_APP="${LOCATION_APP:-owntracks}"
DASH_PERM="${TWS_DASHBOARD_PERM:-synapse.family_dashboard}"

YNH_JSON="${TW_STACK_ROOT}/family/synapse_module"
ynh_group_exists() {
  local g=$1
  yunohost user group list --output-as json | python3 -c "
import json, sys
sys.path.insert(0, '${YNH_JSON}')
from tinywebstack_family.yunohost_json import group_exists
sys.exit(0 if group_exists(json.load(sys.stdin), sys.argv[1]) else 1)
" "$g"
}

ynh_perm_exists() {
  local p=$1
  yunohost user permission list --output-as json | python3 -c "
import json, sys
sys.path.insert(0, '${YNH_JSON}')
from tinywebstack_family.yunohost_json import permission_exists
sys.exit(0 if permission_exists(json.load(sys.stdin), sys.argv[1]) else 1)
" "$p"
}

_YNH_APPS_JSON_LOADED=0
_YNH_APPS_JSON=""
ynh_app_installed() {
  local app_id=$1
  if [[ "$_YNH_APPS_JSON_LOADED" -eq 0 ]]; then
    _YNH_APPS_JSON="$(yunohost app list --output-as json 2>/dev/null || echo '{}')"
    _YNH_APPS_JSON_LOADED=1
  fi
  python3 -c "
import json, sys
data = json.loads(sys.argv[1])
apps = data.get('apps', data)
app_id = sys.argv[2]
if isinstance(apps, dict):
    sys.exit(0 if app_id in apps else 1)
if isinstance(apps, list):
    sys.exit(0 if app_id in apps else 1)
sys.exit(1)
" "$_YNH_APPS_JSON" "$app_id"
}

ensure_group() {
  local g=$1
  if ynh_group_exists "$g"; then
    log "Group ${g} already exists"
  else
    yunohost user group create "$g"
    log "Created group ${g}"
  fi
}

perm_add() {
  yunohost user permission add "$1" "$2" || log "WARN: permission add ${1} ${2} (may already be granted)"
}

perm_remove() {
  local out
  out="$(yunohost user permission remove "$1" "$2" 2>&1)" || {
    if [[ "$out" == *protected* ]]; then
      return 0
    fi
    log "WARN: permission remove $1 $2: ${out}"
  }
}

ensure_group "$PARENTS_GROUP"
ensure_group "$KIDS_GROUP"
ensure_group "$FED_TEST_GROUP"

for perm in synapse.main element.main; do
  perm_remove "$perm" all_users || true
  perm_remove "$perm" visitors || true
  perm_add "$perm" "$PARENTS_GROUP"
  perm_add "$perm" "$KIDS_GROUP"
  perm_add "$perm" "$FED_TEST_GROUP"
done

if ynh_perm_exists nextcloud.main; then
  perm_remove nextcloud.main all_users || true
  perm_add nextcloud.main visitors || true
  perm_add nextcloud.main "$PARENTS_GROUP"
  perm_add nextcloud.main "$KIDS_GROUP"
  perm_add nextcloud.main "$FED_TEST_GROUP"
  hide_portal_tile nextcloud.main
fi

if [[ "$LOCATION_APP" == "owntracks" ]] && ynh_app_installed owntracks; then
  perm_remove owntracks.main all_users || true
  perm_remove owntracks.main visitors || true
  perm_remove owntracks.main "$KIDS_GROUP" || true
  perm_add owntracks.main "$PARENTS_GROUP"
elif [[ "$LOCATION_APP" == "traccar" ]] && ynh_app_installed traccar; then
  perm_remove traccar.main all_users || true
  perm_remove traccar.main visitors || true
  perm_remove traccar.main "$KIDS_GROUP" || true
  perm_add traccar.main "$PARENTS_GROUP"
fi

if ynh_perm_exists "$DASH_PERM"; then
  perm_remove "$DASH_PERM" all_users || true
  perm_remove "$DASH_PERM" visitors || true
  perm_add "$DASH_PERM" "$PARENTS_GROUP"
  configure_family_home_tile "$DASH_PERM" || log "WARN: Family home portal tile not fully configured for ${DASH_PERM}"
fi

EVENTS_APP="${EVENTS_APP:-mobilizon}"
if [[ "$EVENTS_APP" == "mobilizon" ]] && ynh_perm_exists "mobilizon.main"; then
  MOB_ADMIN="${MOBILIZON_ADMIN_USER:-${YUNOHOST_ADMIN_USER:-twsowner}}"
  SETUP_PY="${TW_STACK_ROOT}/lib/setup_mobilizon_permissions.py"
  if [[ -f "$SETUP_PY" ]]; then
    python3 "$SETUP_PY" \
      --parents-group "$PARENTS_GROUP" \
      --federation-test-group "$FED_TEST_GROUP" \
      --admin-user "$MOB_ADMIN" || die "mobilizon SSO/federation permissions failed"
    hide_portal_tile mobilizon.federation || true
  fi
  perm_remove mobilizon.main all_users || true
  perm_remove mobilizon.main visitors || true
  perm_remove mobilizon.main "$KIDS_GROUP" || true
  perm_add mobilizon.main "$PARENTS_GROUP"
  perm_add mobilizon.main "$FED_TEST_GROUP"
  perm_add mobilizon.main "$MOB_ADMIN" || true
  if ! configure_events_tile_logo mobilizon.main; then
    show_portal_tile mobilizon.main --label "Events"
  fi
  APPLY_PY="${TW_STACK_ROOT}/lib/apply_mobilizon_permissions.py"
  if [[ -f "$APPLY_PY" && -f /etc/tinywebstack/family-policy.json ]]; then
    # shellcheck source=scripts/lib/mobilizon_python_path.sh
    source "${TW_STACK_ROOT}/lib/mobilizon_python_path.sh"
    export_mobilizon_pythonpath
    MAIN_DOMAIN="${TWS_SERVER_NAME:-}"
    if [[ -z "$MAIN_DOMAIN" && -f /etc/tinywebstack/dashboard.env ]]; then
      # shellcheck source=/dev/null
      source /etc/tinywebstack/dashboard.env
      MAIN_DOMAIN="${TWS_SERVER_NAME:-}"
    fi
    python3 "$APPLY_PY" \
      --kids-group "$KIDS_GROUP" \
      --parents-group "$PARENTS_GROUP" \
      --federation-test-group "$FED_TEST_GROUP" \
      --admin-user "$MOB_ADMIN" \
      --main-domain "$MAIN_DOMAIN" || log "WARN: mobilizon kid permissions"
  fi
fi

configure_element_tile_logo || true

# Traccar is fallback-only; Owntracks map is linked from the dashboard (avoid broken portal tiles).
if ynh_app_installed traccar; then
  hide_portal_tile traccar.main
fi
if ynh_app_installed owntracks; then
  hide_portal_tile owntracks.main
fi

log "Family groups and permissions applied (${PARENTS_GROUP}, ${KIDS_GROUP}, ${FED_TEST_GROUP})"
