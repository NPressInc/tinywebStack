#!/usr/bin/env bash
# Create family member users (idempotent).
#
# Default list is the lab pair (parent + kid) so the existing spark flow is unchanged.
# Override with --users "william,sophie,emma" or TWS_FAMILY_USERS="william,sophie,emma".
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${TW_STACK_ROOT}/lib/secrets.sh"
# shellcheck source=scripts/lib/family_users.sh
source "${TW_STACK_ROOT}/lib/family_users.sh"
load_config

usage() {
  cat <<'EOF'
Usage: create-family-test-users.sh MAIN_DOMAIN NODE_NAME [--users "u1,u2,..."]

Creates each family member (idempotent) and adds them to the parents/kids LDAP
groups. User list priority: --users flag > TWS_FAMILY_USERS env > lab default
(parent,kid). By default the first user joins the parents group and the rest
join the kids group (override with TWS_FAMILY_PARENTS / TWS_FAMILY_KIDS).
Password for each user comes from <USER>_PASSWORD (uppercased) or the
<user>_password node secret; the lab parent/kid defaults keep the spark flow
working unchanged.
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage
MAIN_DOMAIN=$1
NODE_NAME=$2
shift 2
EXTRA_ARGS=("$@")

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

PARENTS_GROUP="${TWS_PARENTS_GROUP:-parents}"
KIDS_GROUP="${TWS_KIDS_GROUP:-kids}"

FAMILY_USERS_CSV="$(resolve_family_users "${EXTRA_ARGS[@]}")"
PARENT_USERS_CSV="$(resolve_family_parents "$FAMILY_USERS_CSV")"
KID_USERS_CSV="$(resolve_family_kids "$FAMILY_USERS_CSV")"

create_user() {
  local user=$1 pass=$2 full=$3
  if yunohost user list --output-as json | python3 -c "import json,sys; u=sys.argv[1]; d=json.load(sys.stdin); users=d.get('users',d); sys.exit(0 if u in users else 1)" "$user"; then
    log "User ${user} already exists"
  else
    [[ -n "$pass" ]] || die "No password for user '${user}': set ${user^^}_PASSWORD or a '${user}_password' node secret for ${NODE_NAME} (spark secrets)"
    yunohost user create "$user" -F "$full" -p "$pass" -d "$MAIN_DOMAIN"
  fi
}

add_to_group() {
  yunohost user group add "$1" "$2"
}

# Password for a user: <USER>_PASSWORD env (name uppercased; dot/hyphen → underscore),
# then <user>_password node secret (covers the legacy lab parent/kid secrets unchanged).
user_password() {
  local user=$1
  local env_key pw
  env_key="$(printf '%s' "$user" | tr '[:lower:].-' '[:upper:]__')_PASSWORD"
  pw="${!env_key:-}"
  if [[ -z "$pw" ]]; then
    pw="$(read_node_secret "$NODE_NAME" "${user}_password" || true)"
  fi
  printf '%s' "$pw"
}

# Display name: lab labels for parent/kid, capitalized name otherwise.
user_fullname() {
  local user=$1
  case "$user" in
    parent) printf 'Parent Test\n' ;;
    kid)    printf 'Kid Test\n' ;;
    *)      printf '%s\n' "$(printf '%s' "${user:0:1}" | tr '[:lower:]' '[:upper:]')${user:1}" ;;
  esac
}

IFS=',' read -r -a _family_users <<< "$FAMILY_USERS_CSV"
declare -A _is_kid=()
if [[ -n "$KID_USERS_CSV" ]]; then
  IFS=',' read -r -a _kid_list <<< "$KID_USERS_CSV"
  for k in "${_kid_list[@]}"; do
    [[ -n "$k" ]] && _is_kid["$k"]=1
  done
fi

for user in "${_family_users[@]}"; do
  pw="$(user_password "$user")"
  create_user "$user" "$pw" "$(user_fullname "$user")"
  if [[ -n "${_is_kid[$user]:-}" ]]; then
    add_to_group "$KIDS_GROUP" "$user"
  else
    add_to_group "$PARENTS_GROUP" "$user"
  fi
done

log "Family users ready on ${MAIN_DOMAIN}: ${FAMILY_USERS_CSV} (parents: ${PARENT_USERS_CSV}; kids: ${KID_USERS_CSV:-none})"
