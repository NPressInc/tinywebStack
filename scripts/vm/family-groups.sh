#!/usr/bin/env bash
# Idempotent parents/kids groups and app permissions for family layer v1.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
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
  yunohost user permission remove "$1" "$2" || true
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

if [[ "$LOCATION_APP" == "owntracks" ]]; then
  perm_remove owntracks.main all_users || true
  perm_remove owntracks.main visitors || true
  perm_remove owntracks.main "$KIDS_GROUP" || true
  perm_add owntracks.main "$PARENTS_GROUP"
elif [[ "$LOCATION_APP" == "traccar" ]]; then
  perm_remove traccar.main all_users || true
  perm_remove traccar.main visitors || true
  perm_remove traccar.main "$KIDS_GROUP" || true
  perm_add traccar.main "$PARENTS_GROUP"
fi

if ynh_perm_exists "$DASH_PERM"; then
  perm_remove "$DASH_PERM" all_users || true
  perm_remove "$DASH_PERM" visitors || true
  perm_add "$DASH_PERM" "$PARENTS_GROUP"
fi

log "Family groups and permissions applied (${PARENTS_GROUP}, ${KIDS_GROUP}, ${FED_TEST_GROUP})"
