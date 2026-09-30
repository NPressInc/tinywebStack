#!/usr/bin/env bash
# Create parent + kid test users for family layer (idempotent).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${TW_STACK_ROOT}/lib/secrets.sh"
load_config

usage() {
  echo "Usage: create-family-test-users.sh MAIN_DOMAIN NODE_NAME"
  exit 1
}

[[ $# -eq 2 ]] || usage
MAIN_DOMAIN=$1
NODE_NAME=$2

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

PARENTS_GROUP="${TWS_PARENTS_GROUP:-parents}"
KIDS_GROUP="${TWS_KIDS_GROUP:-kids}"
PARENT_USER="${TWS_PARENT_USER:-parent}"
KID_USER="${TWS_KID_USER:-kid}"

validate_test_user_name "$PARENT_USER" parent-user
validate_test_user_name "$KID_USER" kid-user
PARENT_PASSWORD="$(user_test_password "$NODE_NAME" "$PARENT_USER" PARENT_PASSWORD)"
KID_PASSWORD="$(user_test_password "$NODE_NAME" "$KID_USER" KID_PASSWORD)"
[[ -n "$PARENT_PASSWORD" && -n "$KID_PASSWORD" ]] || \
  die "Passwords for ${PARENT_USER}/${KID_USER} required (env ${PARENT_USER^^}_PASSWORD / ${KID_USER^^}_PASSWORD or spark secrets)"

create_user() {
  local user=$1 pass=$2 full=$3
  if yunohost user list --output-as json | python3 -c "import json,sys; u=sys.argv[1]; d=json.load(sys.stdin); users=d.get('users',d); sys.exit(0 if u in users else 1)" "$user"; then
    log "User ${user} already exists"
  else
    yunohost user create "$user" -F "$full" -p "$pass" -d "$MAIN_DOMAIN"
  fi
}

add_to_group() {
  yunohost user group add "$1" "$2"
}

create_user "$PARENT_USER" "$PARENT_PASSWORD" "Parent Test"
create_user "$KID_USER" "$KID_PASSWORD" "Kid Test"
add_to_group "$PARENTS_GROUP" "$PARENT_USER"
add_to_group "$KIDS_GROUP" "$KID_USER"

log "Family test users ${PARENT_USER}/${KID_USER} ready on ${MAIN_DOMAIN}"
