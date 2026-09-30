#!/usr/bin/env bash
# Secret file helpers (never print secret values to stdout).
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

secrets_dir() {
  printf '%s\n' "${TW_STACK_SECRETS_DIR:-${HOME}/.tinywebstack-secrets}"
}

secrets_file() {
  printf '%s\n' "${TW_STACK_SECRETS_FILE:-$(secrets_dir)/passwords.env}"
}

ensure_secrets_dir() {
  local d
  d="$(secrets_dir)"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  mkdir -p "$d"
  chmod 700 "$d"
}

# shellcheck disable=SC2034
load_secrets() {
  local f
  f="$(secrets_file)"
  if [[ -f "$f" ]]; then
    # shellcheck source=/dev/null
    source "$f"
  fi
}

validate_spark_node_name() {
  local node=$1
  local ctx=${2:-secrets lookup}
  if [[ "$node" == *.* ]]; then
    die "Invalid node name '${node}' for ${ctx} (looks like a domain). Use the spark node id (e.g. family-a), not family-a.family.test. Example: remote-run.sh \"\$IP\" install-family-dashboard.sh family-a.family.test family-a"
  fi
  if [[ ! "$node" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    die "Invalid node name '${node}' for ${ctx} (use letters, digits, hyphen, underscore; e.g. family-a)"
  fi
}

secret_key_for_node() {
  local node=$1
  local kind=${2:-yunohost_admin_password}
  validate_spark_node_name "$node"
  # Dots/hyphens in kind (e.g. user names like "mom.dad" -> "mom_dad_password")
  # map to underscores so the key stays a valid bash identifier.
  printf '%s_%s' "$(echo "$kind" | tr '.-' '__' | tr '[:lower:]' '[:upper:]')" "$(echo "$node" | tr '[:lower:]-' '[:upper:]_')"
}

read_node_secret() {
  local node=$1
  local kind=${2:-yunohost_admin_password}
  local key
  key="$(secret_key_for_node "$node" "$kind")"
  load_secrets
  # shellcheck disable=SC2154
  printf '%s\n' "${!key:-}"
}

# Validate a participant/test username (YunoHost-safe: lowercase, digits, dot, dash, underscore).
validate_test_user_name() {
  local user=$1 ctx=${2:-test user}
  if [[ ! "$user" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    die "Invalid ${ctx} name '${user}' (lowercase letters, digits, dot, hyphen, underscore; must start with a letter or digit)"
  fi
}

# Env var name holding a test user's password: "mom.dad" -> MOM_DAD_PASSWORD.
# Dots and hyphens map to underscores so realistic household names work.
test_password_env_key() {
  printf '%s_PASSWORD' "$(printf '%s' "$1" | tr '.-' '__' | tr '[:lower:]' '[:upper:]')"
}

# Resolve the password for an arbitrary test user on a node (verifiers, test-user scripts).
# Args: NODE USER [EXTRA_ENV_KEY ...]
# Order (first hit wins):
#   1. Env var derived from the username, e.g. user "alice" -> $ALICE_PASSWORD
#      ("mom.dad" -> $MOM_DAD_PASSWORD), then each EXTRA_ENV_KEY given.
#      Covers the spark lab: load_secrets() has already sourced passwords.env,
#      so legacy keys like PARENT_PASSWORD resolve here (same source the old
#      hard-coded lookups used).
#   2. The spark secrets store via read_node_secret with kind "<user>_password"
#      (user "alice" on node "family-a" -> key ALICE_PASSWORD_FAMILY_A).
# With the today-default users (alice/bob/parent/kid) this is byte-for-byte the old
# hard-coded behaviour; custom household names just work with no secrets-store edit.
user_test_password() {
  local node=$1 user=$2
  shift 2
  local envkey
  validate_test_user_name "$user" "test user"
  for envkey in "$(test_password_env_key "$user")" "$@"; do
    if [[ -n "${!envkey:-}" ]]; then
      printf '%s\n' "${!envkey}"
      return 0
    fi
  done
  read_node_secret "$node" "${user}_password" || true
}

# Locate a lab CA bundle. Prints the path and returns 0 if an explicit
# TWS_CA_BUNDLE file or a lab CA exists; returns 1 (no output) otherwise —
# callers fall back to the system trust store instead of dying. Callers check
# TWS_REQUIRE_LAB_CA themselves (die inside a command substitution would be
# swallowed by the subshell).
resolve_ca_bundle() {
  local c
  if [[ -n "${TWS_CA_BUNDLE:-}" ]]; then
    if [[ -f "${TWS_CA_BUNDLE}" ]]; then
      printf '%s\n' "${TWS_CA_BUNDLE}"
      return 0
    fi
    log "WARN: TWS_CA_BUNDLE set but file not found (${TWS_CA_BUNDLE}); falling back to lab CA paths"
  fi
  for c in \
    "${TW_STACK_LAB_CA_DIR:-}/lab-ca.crt.pem" \
    "${TW_STACK_ROOT}/lab-certs/lab-ca.crt.pem" \
    "${TW_STACK_SECRETS_DIR:-}/lab-ca/lab-ca.crt.pem"
  do
    if [[ -f "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# Call after resolving a CA: exits if the caller was told a lab CA is mandatory.
require_ca_bundle_or_die() {
  local ca=$1
  [[ -n "$ca" || "${TWS_REQUIRE_LAB_CA:-0}" != "1" ]] || \
    die "Lab CA not found (set TW_STACK_LAB_CA_DIR, export TWS_CA_BUNDLE, run stage-lab-certs.sh, or unset TWS_REQUIRE_LAB_CA)"
}

# Password for spark-generated test node secrets (see ensure-node-secrets.sh).
generate_test_password() {
  if [[ -n "${LAB_PASSWORD:-}" ]]; then
    if [[ ${#LAB_PASSWORD} -lt 8 ]]; then
      log "WARN: LAB_PASSWORD is under 8 characters; YunoHost may reject user/admin passwords"
    fi
    printf '%s' "$LAB_PASSWORD"
    return 0
  fi
  openssl rand -base64 18
}

write_node_secret() {
  local node=$1
  local kind=$2
  local value=$3
  local key f tmp
  if [[ "${TW_STACK_IS_REMOTE:-0}" == "1" || "${DRY_RUN:-0}" == "1" ]]; then
    log "Skip writing secret ${kind} for ${node} (remote or DRY_RUN)"
    return 0
  fi
  key="$(secret_key_for_node "$node" "$kind")"
  ensure_secrets_dir
  f="$(secrets_file)"
  tmp="$(mktemp)"
  if [[ -f "$f" ]]; then
    grep -Ev "^${key}=" "$f" > "$tmp" || true
  fi
  printf '%s=%q\n' "$key" "$value" >> "$tmp"
  install -m 600 "$tmp" "$f"
  rm -f "$tmp"
  log "Stored ${kind} for node ${node} in $(secrets_file)"
}
