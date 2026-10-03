#!/usr/bin/env bash
# Load and validate tinyweb.env for the one-box installer (no secrets).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/domains.sh"
# shellcheck source=scripts/lib/secrets.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets.sh"
# shellcheck source=scripts/lib/family_users.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/family_users.sh"

tinyweb_install_known_keys() {
  cat <<'EOF'
TWS_DOMAIN
TWS_NODE_NAME
TWS_MODE
TWS_ADMIN_USER
LOCATION_APP
EVENTS_APP
TWS_FAMILY_USERS
TWS_FAMILY_PARENTS
TWS_FAMILY_KIDS
TWS_FAMILY_OWNER
TWS_LE_EMAIL
TWS_LAB_CERTS_DIR
TWS_PEERS_HOSTS_FILE
TWS_SWAP
LAB_PASSWORD
TWS_LAB_TLS_INSECURE
FEDERATION_IP_RANGE_WHITELIST
TWS_ALICE_USER
TWS_BOB_USER
TWS_PARENT_USER
TWS_KID_USER
EOF
}

validate_tws_domain() {
  local d=$1
  if [[ -z "$d" ]]; then
    die "TWS_DOMAIN is required"
  fi
  if [[ "$d" == *".."* || "$d" == .* || "$d" == *"." ]]; then
    die "Invalid TWS_DOMAIN '${d}' (must be a bare hostname)"
  fi
  if [[ ! "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    die "Invalid TWS_DOMAIN '${d}' (letters, digits, dot, hyphen)"
  fi
}

default_tws_node_name() {
  local domain=$1
  printf '%s' "${domain%%.*}"
}

# Load tinyweb.env into the current shell (caller must not log this file).
load_tinyweb_env_file() {
  local f=$1
  [[ -f "$f" ]] || die "Config not found: ${f}"
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    if [[ "$line" != *=* ]]; then
      die "Invalid line in ${f} (expected KEY=value): ${line}"
    fi
    key="${line%%=*}"
    val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      die "Invalid key in ${f}: ${key}"
    fi
    # shellcheck disable=SC2163
    export "$key=$val"
  done <"$f"
}

apply_tinyweb_env_defaults() {
  TWS_MODE="${TWS_MODE:-production}"
  case "$TWS_MODE" in
    lab|production) ;;
    *) die "TWS_MODE must be lab or production (got '${TWS_MODE}')" ;;
  esac

  validate_tws_domain "${TWS_DOMAIN:-}"
  TWS_NODE_NAME="${TWS_NODE_NAME:-$(default_tws_node_name "$TWS_DOMAIN")}"
  validate_spark_node_name "$TWS_NODE_NAME" "TWS_NODE_NAME"

  TWS_ADMIN_USER="${TWS_ADMIN_USER:-twsowner}"
  export YUNOHOST_ADMIN_USER="$TWS_ADMIN_USER"

  LOCATION_APP="${LOCATION_APP:-owntracks}"
  case "$LOCATION_APP" in
    owntracks|traccar) ;;
    *) die "LOCATION_APP must be owntracks or traccar" ;;
  esac

  EVENTS_APP="${EVENTS_APP:-mobilizon}"
  TWS_SWAP="${TWS_SWAP:-auto}"
  case "$TWS_SWAP" in
    auto|off) ;;
    [0-9]*) ;;
    *) die "TWS_SWAP must be auto, off, or a positive integer (MB)" ;;
  esac

  if [[ "$TWS_MODE" == "production" && -n "${LAB_PASSWORD:-}" ]]; then
    die "LAB_PASSWORD is lab-only; remove it when TWS_MODE=production"
  fi

  if [[ "$TWS_MODE" == "production" ]]; then
    TWS_LAB_TLS_INSECURE="${TWS_LAB_TLS_INSECURE:-0}"
  else
    TWS_LAB_TLS_INSECURE="${TWS_LAB_TLS_INSECURE:-1}"
  fi

  if [[ -n "${TWS_FAMILY_USERS:-}" ]]; then
    TWS_FAMILY_USERS="$(normalize_user_list "$TWS_FAMILY_USERS")"
  fi
}

tinyweb_config_summary_lines() {
  printf 'TWS_DOMAIN=%s\n' "$TWS_DOMAIN"
  printf 'TWS_NODE_NAME=%s\n' "$TWS_NODE_NAME"
  printf 'TWS_MODE=%s\n' "$TWS_MODE"
  printf 'TWS_ADMIN_USER=%s\n' "$TWS_ADMIN_USER"
  printf 'LOCATION_APP=%s\n' "$LOCATION_APP"
  printf 'EVENTS_APP=%s\n' "$EVENTS_APP"
  printf 'TWS_FAMILY_USERS=%s\n' "${TWS_FAMILY_USERS:-parent,kid (default)}"
  printf 'TWS_SWAP=%s\n' "$TWS_SWAP"
  printf 'TWS_LAB_TLS_INSECURE=%s\n' "$TWS_LAB_TLS_INSECURE"
  if [[ -n "${TWS_LAB_CERTS_DIR:-}" ]]; then
    printf 'TWS_LAB_CERTS_DIR=%s\n' "$TWS_LAB_CERTS_DIR"
  fi
  if [[ -n "${TWS_PEERS_HOSTS_FILE:-}" ]]; then
    printf 'TWS_PEERS_HOSTS_FILE=%s\n' "$TWS_PEERS_HOSTS_FILE"
  fi
  if [[ "$TWS_MODE" == "lab" && -n "${LAB_PASSWORD:-}" ]]; then
    printf 'LAB_PASSWORD=(set)\n'
  fi
}

# Fail fast when lab TLS assets are incomplete (TWS_LAB_CERTS_DIR set in lab mode).
validate_lab_certs_dir() {
  [[ "${TWS_MODE:-}" == "lab" ]] || return 0
  [[ -n "${TWS_LAB_CERTS_DIR:-}" ]] || return 0
  [[ -d "${TWS_LAB_CERTS_DIR}" ]] || die "TWS_LAB_CERTS_DIR is not a directory: ${TWS_LAB_CERTS_DIR}"

  local ca="${TWS_LAB_CERTS_DIR}/lab-ca.crt.pem"
  if [[ ! -f "$ca" ]]; then
    ca="${TWS_LAB_CERTS_DIR}/../lab-ca.crt.pem"
  fi
  [[ -f "$ca" ]] || die "Lab preflight: missing lab-ca.crt.pem under ${TWS_LAB_CERTS_DIR} (or parent dir)"

  local cert_dir="${TWS_LAB_CERTS_DIR}"
  if [[ -d "${TWS_LAB_CERTS_DIR}/certs" ]]; then
    cert_dir="${TWS_LAB_CERTS_DIR}/certs"
  fi

  local d
  while read -r d; do
    [[ -n "$d" ]] || continue
    if [[ ! -f "${cert_dir}/${d}/fullchain.pem" ]]; then
      die "Lab preflight: missing ${cert_dir}/${d}/fullchain.pem (required for domain ${d})"
    fi
  done < <(node_all_domains "${TWS_DOMAIN}")
}
