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

ensure_group() {
  local g=$1
  if yunohost user group list 2>/dev/null | grep -qw "$g"; then
    log "Group ${g} already exists"
  else
    yunohost user group create "$g"
    log "Created group ${g}"
  fi
}

ensure_group "$PARENTS_GROUP"
ensure_group "$KIDS_GROUP"

perm_update() {
  local perm=$1
  shift
  yunohost user permission update "$perm" "$@" 2>/dev/null || true
}

# Matrix / Element: kids and parents need client access; drop broad all_users where present.
for perm in synapse.main element.main; do
  perm_update "$perm" --remove all_users 2>/dev/null || true
  perm_update "$perm" --add "$PARENTS_GROUP"
  perm_update "$perm" --add "$KIDS_GROUP"
done

# Location web UI: parents only (kids publish via mobile app).
if [[ "$LOCATION_APP" == "owntracks" ]]; then
  perm_update owntracks.main --remove all_users 2>/dev/null || true
  perm_update owntracks.main --remove visitors 2>/dev/null || true
  perm_update owntracks.main --remove "$KIDS_GROUP" 2>/dev/null || true
  perm_update owntracks.main --add "$PARENTS_GROUP"
elif [[ "$LOCATION_APP" == "traccar" ]]; then
  perm_update traccar.main --remove all_users 2>/dev/null || true
  perm_update traccar.main --remove visitors 2>/dev/null || true
  perm_update traccar.main --remove "$KIDS_GROUP" 2>/dev/null || true
  perm_update traccar.main --add "$PARENTS_GROUP"
fi

# Family dashboard permission (custom SSO path); created by install-family-dashboard.sh
if yunohost user permission list 2>/dev/null | grep -qw "family-dashboard.main"; then
  perm_update family-dashboard.main --remove all_users 2>/dev/null || true
  perm_update family-dashboard.main --add "$PARENTS_GROUP"
fi

log "Family groups and permissions applied (${PARENTS_GROUP}, ${KIDS_GROUP})"
