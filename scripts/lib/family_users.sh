#!/usr/bin/env bash
# Resolve the family member user list for provisioning scripts.
#
# Priority (highest wins): --users "a,b,c" CLI flag > TWS_FAMILY_USERS env > lab default.
# The lab default ("parent,kid") keeps the existing spark flow unchanged.
#
# Sourcing scripts must source scripts/lib/common.sh first (for die/log).
# shellcheck disable=SC2034

# Users created by create-family-test-users.sh and provisioned by setup-family-calendars.sh
# when neither --users nor TWS_FAMILY_USERS is provided.
TWS_FAMILY_USERS_DEFAULT="parent,kid"

# Owner of the shared calendars (tws-family/tws-parents/tws-kids). Empty = first user in the list.
TWS_FAMILY_OWNER="${TWS_FAMILY_OWNER:-}"

# Parent (adult) users. Empty = first user of the list (lab default list: "parent").
TWS_FAMILY_PARENTS="${TWS_FAMILY_PARENTS:-}"

# Kid users. Empty = every user after the first (lab default list: "kid"). May be empty.
TWS_FAMILY_KIDS="${TWS_FAMILY_KIDS:-}"

# Trim surrounding whitespace from $1.
_trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Normalize a comma-separated user list: trim spaces, drop empties, dedupe preserving
# order, reject invalid names. Prints the normalized CSV; dies on invalid/empty input.
normalize_user_list() {
  local raw=$1
  local -a out=()
  local u existing
  local IFS=','
  local -a entries=()
  read -r -a entries <<< "$raw" || true
  for u in "${entries[@]:-}"; do
    u="$(_trim "$u")"
    [[ -z "$u" ]] && continue
    if [[ ! "$u" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
      die "Invalid family user name '${u}' (use lowercase letters, digits, dot, hyphen, underscore)"
    fi
    local dup=0
    for existing in "${out[@]:-}"; do
      if [[ "$existing" == "$u" ]]; then dup=1; break; fi
    done
    [[ "$dup" -eq 0 ]] && out+=("$u")
  done
  if [[ ${#out[@]} -eq 0 ]]; then
    die "Empty family user list (got: '${raw}')"
  fi
  ( IFS=','; printf '%s\n' "${out[*]}" )
}

# Extract --users value from an argument list ("" when absent). Accepts --users CSV and --users=CSV.
extract_users_flag() {
  local cli_users=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --users)
        [[ $# -ge 2 ]] || die "--users requires a comma-separated value"
        cli_users=$2
        shift 2
        ;;
      --users=*)
        cli_users="${1#--users=}"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done
  printf '%s' "$cli_users"
}

# Print the normalized family user list. Pass through the script's extra args.
resolve_family_users() {
  local cli_users
  cli_users="$(extract_users_flag "$@")"
  if [[ -n "$cli_users" ]]; then
    normalize_user_list "$cli_users"
  elif [[ -n "${TWS_FAMILY_USERS:-}" ]]; then
    normalize_user_list "$TWS_FAMILY_USERS"
  else
    printf '%s\n' "$TWS_FAMILY_USERS_DEFAULT"
  fi
}

# Print the calendar owner (first user unless TWS_FAMILY_OWNER overrides). Arg: normalized CSV.
resolve_family_owner() {
  local users_csv=$1
  if [[ -n "${TWS_FAMILY_OWNER:-}" ]]; then
    printf '%s\n' "$TWS_FAMILY_OWNER"
  else
    printf '%s\n' "${users_csv%%,*}"
  fi
}

# Print parent users as CSV. Args: normalized list CSV.
resolve_family_parents() {
  local users_csv=$1
  if [[ -n "${TWS_FAMILY_PARENTS:-}" ]]; then
    normalize_user_list "$TWS_FAMILY_PARENTS"
    return 0
  fi
  if [[ "$users_csv" == "$TWS_FAMILY_USERS_DEFAULT" ]]; then
    printf 'parent\n'
  else
    printf '%s\n' "${users_csv%%,*}"
  fi
}

# Require explicit parent/kid role lists for custom households (not the lab parent,kid pair).
assert_family_roles_configured() {
  local users_csv=$1
  if [[ "$users_csv" == "$TWS_FAMILY_USERS_DEFAULT" ]]; then
    return 0
  fi
  if [[ -z "${TWS_FAMILY_PARENTS+set}" || -z "${TWS_FAMILY_KIDS+set}" ]]; then
    die "Custom family user list (${users_csv}) requires TWS_FAMILY_PARENTS and TWS_FAMILY_KIDS (comma-separated; kids may be empty). Example: TWS_FAMILY_USERS=william,sophie,emma TWS_FAMILY_PARENTS=william,sophie TWS_FAMILY_KIDS=emma"
  fi
  local parents_csv kids_csv=""
  parents_csv="$(normalize_user_list "$TWS_FAMILY_PARENTS")"
  if [[ -n "${TWS_FAMILY_KIDS}" ]]; then
    kids_csv="$(normalize_user_list "$TWS_FAMILY_KIDS")"
  fi
  local u p k found
  local IFS=','
  local -a all=() par=() kd=()
  read -r -a all <<< "$users_csv"
  read -r -a par <<< "$parents_csv"
  read -r -a kd <<< "$kids_csv"
  for u in "${all[@]}"; do
    found=0
    for p in "${par[@]}"; do [[ "$p" == "$u" ]] && found=1 && break; done
    if [[ "$found" -eq 1 ]]; then continue; fi
    for k in "${kd[@]}"; do [[ "$k" == "$u" ]] && found=1 && break; done
    if [[ "$found" -eq 0 ]]; then
      die "User '${u}' is in TWS_FAMILY_USERS but not in TWS_FAMILY_PARENTS or TWS_FAMILY_KIDS"
    fi
  done
}

# Print kid users as CSV (may be empty). Args: normalized list CSV.
resolve_family_kids() {
  local users_csv=$1
  if [[ -n "${TWS_FAMILY_KIDS+set}" ]]; then
    if [[ -z "${TWS_FAMILY_KIDS}" ]]; then
      if [[ "$users_csv" == "$TWS_FAMILY_USERS_DEFAULT" ]]; then
        : # explicit empty kids on a custom list only; lab default falls through
      else
        printf '\n'
        return 0
      fi
    else
      normalize_user_list "$TWS_FAMILY_KIDS"
      return 0
    fi
  fi
  if [[ "$users_csv" == "$TWS_FAMILY_USERS_DEFAULT" ]]; then
    printf 'kid\n'
  elif [[ "$users_csv" == *,* ]]; then
    # Everyone after the first user joins the kids group (parents-group membership is
    # creation-time only; use TWS_FAMILY_PARENTS/TWS_FAMILY_KIDS for other splits).
    printf '%s\n' "${users_csv#*,}"
  else
    printf '\n'
  fi
}
