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

PARENT_PASSWORD="${PARENT_PASSWORD:-$(read_node_secret "$NODE_NAME" parent_password || true)}"
KID_PASSWORD="${KID_PASSWORD:-$(read_node_secret "$NODE_NAME" kid_password || true)}"
[[ -n "$PARENT_PASSWORD" && -n "$KID_PASSWORD" ]] || die "PARENT_PASSWORD and KID_PASSWORD required (spark secrets)"

create_user() {
  local user=$1 pass=$2 full=$3
  if yunohost user list 2>/dev/null | grep -qw "$user"; then
    log "User ${user} already exists"
  else
    yunohost user create "$user" -F "$full" -p "$pass" -d "$MAIN_DOMAIN"
  fi
}

add_to_group() {
  local user=$1 group=$2
  yunohost user group adduser "$group" "$user" 2>/dev/null || true
}

create_user parent "$PARENT_PASSWORD" "Parent Test"
create_user kid "$KID_PASSWORD" "Kid Test"
add_to_group parent "$PARENTS_GROUP"
add_to_group kid "$KIDS_GROUP"

log "Family test users parent/kid ready on ${MAIN_DOMAIN}"
