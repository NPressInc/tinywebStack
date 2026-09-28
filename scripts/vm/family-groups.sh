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
LOCATION_APP="${LOCATION_APP:-owntracks}"
DASH_PERM="${TWS_DASHBOARD_PERM:-core_family.main}"

ensure_group() {
  local g=$1
  if yunohost user group list --output-as json | python3 -c "import json,sys; g=sys.argv[1]; d=json.load(sys.stdin); sys.exit(0 if g in d else 1)" "$g" 2>/dev/null; then
    log "Group ${g} already exists"
  else
    yunohost user group create "$g"
    log "Created group ${g}"
  fi
}

perm_add() {
  yunohost user permission add "$1" "$2"
}

perm_remove() {
  yunohost user permission remove "$1" "$2" || true
}

ensure_group "$PARENTS_GROUP"
ensure_group "$KIDS_GROUP"

for perm in synapse.main element.main; do
  perm_remove "$perm" all_users || true
  perm_remove "$perm" visitors || true
  perm_add "$perm" "$PARENTS_GROUP"
  perm_add "$perm" "$KIDS_GROUP"
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

if yunohost user permission list --output-as json | python3 -c "import json,sys; p=sys.argv[1]; d=json.load(sys.stdin); sys.exit(0 if p in d else 1)" "$DASH_PERM" 2>/dev/null; then
  perm_remove "$DASH_PERM" all_users || true
  perm_remove "$DASH_PERM" visitors || true
  perm_add "$DASH_PERM" "$PARENTS_GROUP"
fi

log "Family groups and permissions applied (${PARENTS_GROUP}, ${KIDS_GROUP})"
