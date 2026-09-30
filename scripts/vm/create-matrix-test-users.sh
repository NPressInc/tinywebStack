#!/usr/bin/env bash
# Create alice/bob YunoHost users for federation tests (idempotent).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${TW_STACK_ROOT}/lib/secrets.sh"
load_config

usage() {
  echo "Usage: create-matrix-test-users.sh MAIN_DOMAIN NODE_NAME"
  exit 1
}

[[ $# -eq 2 ]] || usage
MAIN_DOMAIN=$1
NODE_NAME=$2

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

ALICE_USER="${TWS_ALICE_USER:-alice}"
BOB_USER="${TWS_BOB_USER:-bob}"
validate_test_user_name "$ALICE_USER" alice-user
validate_test_user_name "$BOB_USER" bob-user
ALICE_PASSWORD="$(user_test_password "$NODE_NAME" "$ALICE_USER" ALICE_PASSWORD)"
BOB_PASSWORD="$(user_test_password "$NODE_NAME" "$BOB_USER" BOB_PASSWORD)"
[[ -n "$ALICE_PASSWORD" && -n "$BOB_PASSWORD" ]] || \
  die "Passwords for ${ALICE_USER}/${BOB_USER} required (env ${ALICE_USER^^}_PASSWORD / ${BOB_USER^^}_PASSWORD or spark secrets)"

FED_TEST_GROUP="${TWS_FEDERATION_TEST_GROUP:-federation-test}"

create_user() {
  local user=$1 pass=$2 full=$3
  if yunohost user list --output-as json | python3 -c "import json,sys; u=sys.argv[1]; d=json.load(sys.stdin); users=d.get('users',d); sys.exit(0 if u in users else 1)" "$user"; then
    log "User ${user} already exists"
  else
    yunohost user create "$user" -F "$full" -p "$pass" -d "$MAIN_DOMAIN"
  fi
  yunohost user group add "$FED_TEST_GROUP" "$user" || true
}

if ! yunohost user group list --output-as json | python3 -c "import json,sys; g=sys.argv[1]; d=json.load(sys.stdin); groups=d.get('groups',d); sys.exit(0 if g in groups else 1)" "$FED_TEST_GROUP"; then
  yunohost user group create "$FED_TEST_GROUP"
fi

create_user alice "$ALICE_PASSWORD" "Alice Test"
create_user bob "$BOB_PASSWORD" "Bob Test"
"${TW_STACK_ROOT}/vm/family-groups.sh" || log "WARN: family-groups after matrix test users"
log "Matrix test users ready on ${MAIN_DOMAIN} (group ${FED_TEST_GROUP})"
