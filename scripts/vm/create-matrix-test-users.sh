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

ALICE_PASSWORD="${ALICE_PASSWORD:-$(read_node_secret "$NODE_NAME" alice_password || true)}"
BOB_PASSWORD="${BOB_PASSWORD:-$(read_node_secret "$NODE_NAME" bob_password || true)}"
[[ -n "$ALICE_PASSWORD" && -n "$BOB_PASSWORD" ]] || die "ALICE_PASSWORD and BOB_PASSWORD required (from spark secrets)"

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
