#!/usr/bin/env bash
# Root-run one-box installer for tinywebStack (Debian 12 / YunoHost 12).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${REPO_ROOT}/scripts/lib/domains.sh"
# shellcheck source=scripts/lib/tinyweb-install-env.sh
source "${REPO_ROOT}/scripts/lib/tinyweb-install-env.sh"
# shellcheck source=scripts/lib/tinyweb-install-secrets.sh
source "${REPO_ROOT}/scripts/lib/tinyweb-install-secrets.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${REPO_ROOT}/scripts/lib/secrets.sh"
# shellcheck source=scripts/lib/family_users.sh
source "${REPO_ROOT}/scripts/lib/family_users.sh"

TWS_INSTALL_ROOT="${TWS_INSTALL_ROOT:-/opt/tinywebstack}"
TWS_ETC_DIR="${TWS_ETC_DIR:-/etc/tinywebstack}"
TINYWEB_INSTALL_LOG="${TINYWEB_INSTALL_LOG:-/var/log/tinywebstack-install.log}"
SKIP_SELFCHECK=0
CONFIG_PATH=""
INSTALL_DRY_RUN=0

INSTALL_STEPS=(
  "0 preflight"
  "1 swapfile"
  "2 yunohost-bootstrap"
  "3 tls"
  "4 yunohost-family-apps"
  "5 create-matrix-test-users (lab only)"
  "6 family-init"
  "7 family-permissions-seed and family-federation-state-seed"
  "8 mobilizon-admin-password"
  "9 family-sync-federation and family-events-perms"
  "10 self-check"
)

usage() {
  cat <<'EOF'
Usage: install-tinyweb.sh [--config /path/tinyweb.env] [--skip-selfcheck] [--dry-run]

Install tinywebStack on this machine (no control machine). Requires root.
Default config: /etc/tinywebstack/tinyweb.env, else ./tinyweb.env at repo root.
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH=$2
      shift 2
      ;;
    --skip-selfcheck)
      SKIP_SELFCHECK=1
      shift
      ;;
    --dry-run)
      INSTALL_DRY_RUN=1
      export DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

install_log() {
  local msg=$1
  log "$msg"
  if [[ "${DRY_RUN:-0}" != "1" && "$(id -u)" -eq 0 ]]; then
    install -d -m 755 -o root -g root "$(dirname "$TINYWEB_INSTALL_LOG")" 2>/dev/null || true
    printf '%s %s\n' "$(date -Is)" "$msg" >>"$TINYWEB_INSTALL_LOG" 2>/dev/null || true
    chmod 600 "$TINYWEB_INSTALL_LOG" 2>/dev/null || true
  fi
}

resolve_config_path() {
  if [[ -n "$CONFIG_PATH" ]]; then
    printf '%s\n' "$CONFIG_PATH"
    return 0
  fi
  if [[ -f "${TWS_ETC_DIR}/tinyweb.env" ]]; then
    printf '%s\n' "${TWS_ETC_DIR}/tinyweb.env"
    return 0
  fi
  if [[ -f "${REPO_ROOT}/tinyweb.env" ]]; then
    printf '%s\n' "${REPO_ROOT}/tinyweb.env"
    return 0
  fi
  die "No config found (use --config or create ${TWS_ETC_DIR}/tinyweb.env)"
}

step_banner() {
  local step=$1
  local title=$2
  local start
  start=$(date +%s)
  install_log "=== Step ${step}: ${title} ==="
  STEP_START=$start
}

step_done() {
  local step=$1
  local end elapsed
  end=$(date +%s)
  elapsed=$((end - STEP_START))
  install_log "=== Step ${step} complete (${elapsed}s) ==="
}

memtotal_kb() {
  if [[ -n "${TWS_MEMTOTAL_KB_OVERRIDE:-}" ]]; then
    printf '%s\n' "$TWS_MEMTOTAL_KB_OVERRIDE"
    return 0
  fi
  awk '/MemTotal:/ {print $2}' /proc/meminfo
}

active_swap_kb() {
  if [[ -n "${TWS_SWAPTOTAL_KB_OVERRIDE:-}" ]]; then
    printf '%s\n' "$TWS_SWAPTOTAL_KB_OVERRIDE"
    return 0
  fi
  awk '/SwapTotal:/ {print $2}' /proc/meminfo
}

should_create_swap() {
  local policy=$1
  case "$policy" in
    off) return 1 ;;
    auto)
      local mem swap
      mem="$(memtotal_kb)"
      swap="$(active_swap_kb)"
      [[ "${mem:-0}" -lt 6291456 && "${swap:-0}" -eq 0 ]]
      ;;
    *)
      return 0
      ;;
  esac
}

swap_size_mb() {
  local policy=$1
  case "$policy" in
    auto) echo 2048 ;;
    [0-9]*) echo "$policy" ;;
    *) die "Invalid TWS_SWAP: ${policy}" ;;
  esac
}

preflight_base_pkg_present() {
  dpkg -s "$1" 2>/dev/null | grep -qFx 'Status: install ok installed'
}

ensure_preflight_base_packages() {
  local pkgs=(rsync curl openssl ca-certificates gnupg)
  local missing=() still_missing=() p apt_update_rc=0
  for p in "${pkgs[@]}"; do
    preflight_base_pkg_present "$p" || missing+=("$p")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi
  install_log "Installing missing base packages: ${missing[*]}"
  if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
    apt_update_rc=$?
    install_log "WARN: apt-get update failed (exit ${apt_update_rc}); continuing with apt-get install"
  fi
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; then
    for p in "${missing[@]}"; do
      preflight_base_pkg_present "$p" || still_missing+=("$p")
    done
    if [[ ${#still_missing[@]} -gt 0 ]]; then
      die "Missing base packages after install attempt: ${still_missing[*]}"
    fi
  fi
}

step_swapfile() {
  step_banner 1 "swapfile"
  if [[ "$TWS_SWAP" == "off" ]]; then
    install_log "TWS_SWAP=off — skipping swap"
    step_done 1
    return 0
  fi
  if ! should_create_swap "$TWS_SWAP"; then
    install_log "Swap step not needed (policy=${TWS_SWAP}, MemTotal=$(memtotal_kb) kB, SwapTotal=$(active_swap_kb) kB)"
    step_done 1
    return 0
  fi
  local size_mb
  size_mb="$(swap_size_mb "$TWS_SWAP")"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    install_log "DRY_RUN: would create /swapfile (${size_mb} MB)"
    step_done 1
    return 0
  fi
  if [[ -f /swapfile ]]; then
    install_log "/swapfile already exists — skipping"
    step_done 1
    return 0
  fi
  fallocate -l "${size_mb}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$size_mb"
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -q '^/swapfile ' /etc/fstab; then
    printf '%s\n' '/swapfile none swap sw 0 0' >>/etc/fstab
  fi
  install -d -m 755 /etc/sysctl.d
  printf '%s\n' 'vm.swappiness=10' >/etc/sysctl.d/99-tinywebstack.conf
  sysctl -p /etc/sysctl.d/99-tinywebstack.conf >/dev/null 2>&1 || true
  step_done 1
}

stage_stack_tree() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    install_log "DRY_RUN: would rsync scripts/ family/ brand/ to ${TWS_INSTALL_ROOT}"
    return 0
  fi
  mkdir -p "$TWS_INSTALL_ROOT"
  rsync -a "${REPO_ROOT}/scripts/" "${TWS_INSTALL_ROOT}/"
  install -m 644 "${REPO_ROOT}/config/defaults.env" "${TWS_INSTALL_ROOT}/defaults.env"
  rsync -a "${REPO_ROOT}/family/" "${TWS_INSTALL_ROOT}/family/"
  rsync -a "${REPO_ROOT}/brand/" "${TWS_INSTALL_ROOT}/brand/"

  if [[ -n "${TWS_LAB_CERTS_DIR:-}" && -d "${TWS_LAB_CERTS_DIR}" ]]; then
    mkdir -p "${TWS_INSTALL_ROOT}/lab-certs"
    if [[ -d "${TWS_LAB_CERTS_DIR}/certs" ]]; then
      rsync -a "${TWS_LAB_CERTS_DIR}/certs/" "${TWS_INSTALL_ROOT}/lab-certs/"
    else
      rsync -a "${TWS_LAB_CERTS_DIR}/" "${TWS_INSTALL_ROOT}/lab-certs/"
    fi
    if [[ -f "${TWS_LAB_CERTS_DIR}/lab-ca.crt.pem" ]]; then
      install -m 644 "${TWS_LAB_CERTS_DIR}/lab-ca.crt.pem" \
        "${TWS_INSTALL_ROOT}/lab-certs/lab-ca.crt.pem"
    elif [[ -f "${TWS_LAB_CERTS_DIR}/../lab-ca.crt.pem" ]]; then
      install -m 644 "${TWS_LAB_CERTS_DIR}/../lab-ca.crt.pem" \
        "${TWS_INSTALL_ROOT}/lab-certs/lab-ca.crt.pem"
    fi
  fi

  if [[ -n "${TWS_PEERS_HOSTS_FILE:-}" && -f "${TWS_PEERS_HOSTS_FILE}" ]]; then
    install -m 644 "${TWS_PEERS_HOSTS_FILE}" "${TWS_INSTALL_ROOT}/peers.hosts"
  fi
}

install_lab_ca_system_trust() {
  [[ "${TWS_MODE:-}" == "lab" ]] || return 0
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    install_log "DRY_RUN: would install lab CA into system trust store"
    return 0
  fi
  local ca="${TWS_INSTALL_ROOT}/lab-certs/lab-ca.crt.pem"
  [[ -f "$ca" ]] || return 0
  install -m 644 "$ca" /usr/local/share/ca-certificates/tinywebstack-lab-ca.crt
  update-ca-certificates >/dev/null 2>&1 || true
  install_log "Installed lab CA into system trust store (tinywebstack-lab-ca.crt)"
}

write_production_dashboard_tls_insecure() {
  [[ "${TWS_MODE:-}" == "production" ]] || return 0
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    install_log "DRY_RUN: would set TWS_LAB_TLS_INSECURE=0 in /etc/tinywebstack/dashboard.env"
    return 0
  fi
  install -d -m 755 /etc/tinywebstack
  local f=/etc/tinywebstack/dashboard.env
  if [[ -f "$f" ]]; then
    if grep -q '^TWS_LAB_TLS_INSECURE=' "$f"; then
      sed -i 's/^TWS_LAB_TLS_INSECURE=.*/TWS_LAB_TLS_INSECURE=0/' "$f"
    else
      printf '%s\n' 'TWS_LAB_TLS_INSECURE=0' >>"$f"
    fi
  else
    printf '%s\n' 'TWS_LAB_TLS_INSECURE=0' >"$f"
  fi
  local grp=root
  if getent group www-data >/dev/null 2>&1; then
    grp=www-data
  fi
  chown root:"$grp" "$f"
  chmod 640 "$f"
}

write_stack_local_env() {
  local dest="${TWS_INSTALL_ROOT}/local.env"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    install_log "DRY_RUN: would write ${dest}"
    return 0
  fi
  cat >"$dest" <<EOF
LOCATION_APP=${LOCATION_APP}
EVENTS_APP=${EVENTS_APP}
YUNOHOST_ADMIN_USER=${YUNOHOST_ADMIN_USER}
TWS_LAB_TLS_INSECURE=${TWS_LAB_TLS_INSECURE}
FEDERATION_IP_RANGE_WHITELIST=${FEDERATION_IP_RANGE_WHITELIST:-192.168.122.0/24}
EOF
  if [[ -n "${TWS_FAMILY_USERS:-}" ]]; then
    printf 'TWS_FAMILY_USERS=%s\n' "$TWS_FAMILY_USERS" >>"$dest"
  fi
  if [[ -n "${TWS_FAMILY_PARENTS:-}" ]]; then
    printf 'TWS_FAMILY_PARENTS=%s\n' "$TWS_FAMILY_PARENTS" >>"$dest"
  fi
  if [[ -n "${TWS_FAMILY_KIDS+set}" ]]; then
    printf 'TWS_FAMILY_KIDS=%s\n' "${TWS_FAMILY_KIDS}" >>"$dest"
  fi
  if [[ -n "${TWS_FAMILY_OWNER:-}" ]]; then
    printf 'TWS_FAMILY_OWNER=%s\n' "$TWS_FAMILY_OWNER" >>"$dest"
  fi
  chmod 644 "$dest"
}

run_vm_with_install_env() {
  local script=$1
  shift
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    install_log "DRY_RUN: vm/${script} $*"
    return 0
  fi
  local _xt=0
  [[ $- == *x* ]] && _xt=1
  set +x
  bash -c 'set -euo pipefail
    set -a
    # shellcheck source=/dev/null
    source "$1"
    set +a
    export TW_STACK_ROOT="$2" TW_STACK_IS_REMOTE=1
    bash "$2/vm/$3" "${@:4}"
  ' bash "$(tinyweb_install_env_path)" "$TWS_INSTALL_ROOT" "$script" "$@"
  if ((_xt)); then set -x; fi
}

domain_has_le_cert() {
  local d=$1
  local crt="/etc/yunohost/certs/${d}/crt.pem"
  [[ -f "$crt" ]] || return 1
  openssl x509 -in "$crt" -noout -issuer 2>/dev/null | grep -qi "Let's Encrypt"
}

step_tls() {
  step_banner 3 "tls"
  if [[ "$TWS_MODE" == "lab" ]]; then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      install_log "DRY_RUN: would run yunohost-lab-tls.sh for domains with lab certs"
      step_done 3
      return 0
    fi
    export TW_STACK_ROOT="$TWS_INSTALL_ROOT"
    load_config
    while read -r d; do
      [[ -n "$d" ]] || continue
      if [[ -f "${TWS_INSTALL_ROOT}/lab-certs/${d}/fullchain.pem" ]]; then
        run_vm_with_install_env yunohost-lab-tls.sh "$d" || true
      fi
    done < <(node_all_domains "$TWS_DOMAIN")
  else
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      install_log "DRY_RUN: would run yunohost domain cert install (Let's Encrypt) per app domain"
      step_done 3
      return 0
    fi
    local d
    while read -r d; do
      [[ -n "$d" ]] || continue
      if domain_has_le_cert "$d"; then
        install_log "LE cert already present for ${d} — skipping"
        continue
      fi
      local le_args=()
      if [[ -n "${TWS_LE_EMAIL:-}" ]]; then
        le_args+=(--email "$TWS_LE_EMAIL")
      fi
      if ! yunohost domain cert install "$d" "${le_args[@]}" --no-checks 2>/dev/null; then
        if ! yunohost domain cert install "$d" "${le_args[@]}"; then
          install_log "WARN: Let's Encrypt failed for ${d}; retry manually: yunohost domain cert install ${d}"
        fi
      fi
    done < <(node_all_domains "$TWS_DOMAIN")
    write_production_dashboard_tls_insecure
  fi
  step_done 3
}

step_preflight() {
  step_banner 0 "preflight"
  if [[ "${DRY_RUN:-0}" != "1" && "$(id -u)" -ne 0 ]]; then
    die "install-tinyweb.sh must run as root (or use --dry-run)"
  fi
  local debian_ver=""
  if [[ -f /etc/debian_version ]]; then
    debian_ver="$(cat /etc/debian_version)"
  fi
  install_log "Host: arch=$(host_debian_arch) debian=${debian_ver:-unknown}"
  if command -v yunohost >/dev/null 2>&1; then
    install_log "YunoHost: $(yunohost --version 2>/dev/null | head -1 || true)"
  fi
  install_log "Memory: MemTotal=$(memtotal_kb) kB SwapTotal=$(active_swap_kb) kB"
  install_log "Disk: $(df -h / | awk 'NR==2 {print $4 " free on " $1}')"
  if [[ "${DRY_RUN:-0}" != "1" ]]; then
    ensure_preflight_base_packages
    require_cmd curl awk rsync openssl
    if ! curl -fsSL --max-time 20 -o /dev/null "${YUNOHOST_INSTALL_URL:-https://install.yunohost.org}"; then
      install_log "WARN: could not reach YunoHost install URL (offline install may fail)"
    fi
  fi
  validate_lab_certs_dir
  stage_stack_tree
  install_lab_ca_system_trust
  write_stack_local_env
  ensure_tinyweb_install_secrets "$TWS_DOMAIN" "$TWS_MODE" "$LOCATION_APP"
  if [[ -f "${TWS_INSTALL_ROOT}/peers.hosts" ]]; then
    run_vm_with_install_env sync-peer-hosts.sh
  fi
  step_done 0
}

step_bootstrap() {
  step_banner 2 "yunohost-bootstrap"
  run_vm_with_install_env yunohost-bootstrap.sh "$TWS_DOMAIN" "$TWS_NODE_NAME"
  step_done 2
}

step_family_apps() {
  step_banner 4 "yunohost-family-apps"
  run_vm_with_install_env yunohost-family-apps.sh "$TWS_DOMAIN" "$TWS_NODE_NAME"
  step_done 4
}

step_matrix_users() {
  if [[ "$TWS_MODE" != "lab" ]]; then
    install_log "Step 5 skipped (not lab mode)"
    return 0
  fi
  step_banner 5 "create-matrix-test-users"
  run_vm_with_install_env create-matrix-test-users.sh "$TWS_DOMAIN" "$TWS_NODE_NAME"
  step_done 5
}

step_family_init() {
  step_banner 6 "family-init"
  run_vm_with_install_env family-init.sh "$TWS_DOMAIN" "$TWS_NODE_NAME"
  step_done 6
}

step_family_seeds() {
  step_banner 7 "family-permissions-seed and family-federation-state-seed"
  run_vm_with_install_env family-permissions-seed.sh "$TWS_DOMAIN"
  run_vm_with_install_env family-federation-state-seed.sh "$TWS_DOMAIN"
  step_done 7
}

step_mobilizon_password() {
  step_banner 8 "mobilizon-admin-password"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    install_log "DRY_RUN: would pipe admin password to tws-store-mobilizon-admin-password.sh"
    step_done 8
    return 0
  fi
  local _xt=0
  [[ $- == *x* ]] && _xt=1
  set +x
  bash -c 'set -euo pipefail
    set -a
    # shellcheck source=/dev/null
    source "$1"
    set +a
    export TW_STACK_ROOT="$2" TW_STACK_IS_REMOTE=1
    printf "%s" "$YUNOHOST_ADMIN_PASSWORD" | bash "$2/vm/tws-store-mobilizon-admin-password.sh"
  ' bash "$(tinyweb_install_env_path)" "$TWS_INSTALL_ROOT"
  if ((_xt)); then set -x; fi
  step_done 8
}

step_federation_sync() {
  step_banner 9 "family-sync-federation and family-events-perms"
  local ec=0
  run_vm_with_install_env family-sync-federation.sh "$TWS_DOMAIN" || ec=$?
  if [[ "$ec" -ne 0 ]]; then
    install_log "WARN: family-sync-federation.sh exited ${ec}"
  fi
  ec=0
  run_vm_with_install_env family-events-perms.sh || ec=$?
  if [[ "$ec" -ne 0 ]]; then
    install_log "WARN: family-events-perms.sh exited ${ec}"
  fi
  step_done 9
}

check_systemd_active() {
  local unit=$1
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    printf 'PASS\t%s active\n' "$unit"
    return 0
  fi
  printf 'FAIL\t%s not active\n' "$unit"
  return 1
}

systemd_unit_file_present() {
  local unit=$1
  systemctl list-unit-files --no-legend "${unit}" 2>/dev/null \
    | awk '{print $1}' | grep -qxF "${unit}"
}

selfcheck_require_unit() {
  local unit=$1
  local line
  if ! systemd_unit_file_present "${unit}.service"; then
    printf 'FAIL\t%s unit missing\n' "$unit"
    return 1
  fi
  line="$(check_systemd_active "$unit" || true)"
  printf '%s\n' "$line"
  [[ "$line" == PASS* ]]
}

selfcheck_require_first_unit() {
  local u line
  for u in "$@"; do
    if systemd_unit_file_present "${u}.service"; then
      line="$(check_systemd_active "$u" || true)"
      printf '%s\n' "$line"
      [[ "$line" == PASS* ]]
      return $?
    fi
  done
  printf 'FAIL\t%s unit missing\n' "$*"
  return 1
}

selfcheck_optional_unit_if_present() {
  local unit=$1
  local line
  if ! systemd_unit_file_present "${unit}.service"; then
    return 0
  fi
  line="$(check_systemd_active "$unit" || true)"
  printf '%s\n' "$line"
  [[ "$line" == PASS* ]]
}

selfcheck_https_curl_opts() {
  local host=$1
  SELFCHECK_CURL_RESOLVE=(--resolve "${host}:443:127.0.0.1")
  SELFCHECK_CURL_CA=()
  local ca="${TWS_INSTALL_ROOT}/lab-certs/lab-ca.crt.pem"
  if [[ -f "$ca" ]]; then
    SELFCHECK_CURL_CA=(--cacert "$ca")
  fi
}

owner_caldav_password() {
  local owner=$1
  if [[ "$owner" == "parent" ]]; then
    user_test_password "$TWS_NODE_NAME" "$owner" PARENT_PASSWORD
  else
    user_test_password "$TWS_NODE_NAME" "$owner"
  fi
}

caldav_propfind_check() {
  local nc_host=$1 owner=$2 pw=$3 nc_path=$4
  local _xt=0 tmpcode
  [[ $- == *x* ]] && _xt=1
  set +x
  tmpcode="$(
    (
      local netrc
      netrc="$(mktemp)"
      chmod 600 "$netrc"
      trap 'rm -f "$netrc"' EXIT
      printf 'machine %s login %s password %s\n' "$nc_host" "$owner" "$pw" >"$netrc"
      curl -sS -o /dev/null -w '%{http_code}' \
        "${SELFCHECK_CURL_RESOLVE[@]}" "${SELFCHECK_CURL_CA[@]}" \
        --netrc-file "$netrc" \
        -X PROPFIND "https://${nc_host}${nc_path}/remote.php/dav/" \
        -H 'Depth: 0' 2>/dev/null || echo 000
    )
  )"
  if ((_xt)); then set -x; fi
  printf '%s' "$tmpcode"
}

step_selfcheck() {
  step_banner 10 "self-check"
  if [[ "$SKIP_SELFCHECK" -eq 1 ]]; then
    install_log "Self-check skipped (--skip-selfcheck)"
    step_done 10
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    install_log "DRY_RUN: would run self-check"
    step_done 10
    return 0
  fi

  local fail=0
  local line owner pw nc_d nc_path tmpcode
  local -a results=()

  for unit in nginx slapd; do
    line="$(selfcheck_require_unit "$unit" || true)"
    results+=("$line")
    [[ "$line" == FAIL* ]] && fail=1
  done

  local pg_checked=0 u
  while read -r u; do
    [[ -n "$u" ]] || continue
    u="${u%.service}"
    line="$(check_systemd_active "$u" || true)"
    results+=("$line")
    [[ "$line" == FAIL* ]] && fail=1
    pg_checked=1
  done < <(systemctl list-units --type=service --all 'postgresql@*-main.service' --no-legend --plain 2>/dev/null \
    | awk '{print $1}')
  if [[ "$pg_checked" -eq 0 ]]; then
    line="$(selfcheck_require_unit postgresql || true)"
    results+=("$line")
    [[ "$line" == FAIL* ]] && fail=1
  fi

  local php_checked=0
  while read -r u; do
    [[ -n "$u" ]] || continue
    u="${u%.service}"
    line="$(check_systemd_active "$u" || true)"
    results+=("$line")
    [[ "$line" == FAIL* ]] && fail=1
    php_checked=1
  done < <(systemctl list-units --type=service --all 'php*-fpm.service' --no-legend --plain 2>/dev/null \
    | awk '{print $1}')
  if [[ "$php_checked" -eq 0 ]]; then
    results+=("FAIL	php*-fpm unit missing")
    fail=1
  fi

  line="$(selfcheck_require_first_unit synapse matrix-synapse || true)"
  results+=("$line")
  [[ "$line" == FAIL* ]] && fail=1

  if [[ "${EVENTS_APP:-mobilizon}" == "mobilizon" ]]; then
    line="$(selfcheck_require_unit mobilizon || true)"
    results+=("$line")
    [[ "$line" == FAIL* ]] && fail=1
  fi

  line="$(selfcheck_require_unit tinywebstack-family-dashboard || true)"
  results+=("$line")
  [[ "$line" == FAIL* ]] && fail=1

  if [[ "$LOCATION_APP" == "owntracks" ]]; then
    line="$(selfcheck_require_first_unit owntracks ot-recorder || true)"
    results+=("$line")
    [[ "$line" == FAIL* ]] && fail=1
  elif [[ "$LOCATION_APP" == "traccar" ]]; then
    line="$(selfcheck_require_unit traccar || true)"
    results+=("$line")
    [[ "$line" == FAIL* ]] && fail=1
  fi

  line="$(selfcheck_optional_unit_if_present redis-server || true)"
  [[ -n "$line" ]] && results+=("$line")
  [[ "$line" == FAIL* ]] && fail=1

  local synapse_token_file="${TWS_ETC_DIR}/synapse-admin-token"
  if [[ -s "$synapse_token_file" ]]; then
    results+=("PASS	synapse-admin-token non-empty")
  else
    results+=("FAIL	synapse-admin-token missing or empty")
    fail=1
  fi

  source_tinyweb_install_env
  export TW_STACK_ROOT="$TWS_INSTALL_ROOT"
  load_config
  local users_csv
  # shellcheck disable=SC2119
  users_csv="$(resolve_family_users)"
  owner="$(resolve_family_owner "$users_csv")"

  if curl -fsS -o /dev/null -w '' -H "YNH_USER: ${owner}" \
    "http://127.0.0.1:8765/permissions/kid" 2>/dev/null; then
    results+=("PASS	dashboard permissions/kid HTTP 200")
  else
    results+=("FAIL	dashboard permissions/kid HTTP")
    fail=1
  fi

  if curl -fsS -o /dev/null -w '' -H "YNH_USER: ${owner}" \
    "http://127.0.0.1:8765/federation/domains" 2>/dev/null; then
    results+=("PASS	dashboard /federation/domains HTTP 200")
  else
    results+=("FAIL	dashboard /federation/domains HTTP")
    fail=1
  fi

  selfcheck_https_curl_opts "$TWS_DOMAIN"
  if curl -fsS -o /dev/null "${SELFCHECK_CURL_RESOLVE[@]}" "${SELFCHECK_CURL_CA[@]}" \
    "https://${TWS_DOMAIN}/_matrix/client/versions" 2>/dev/null; then
    results+=("PASS	Synapse client versions HTTPS 200")
  else
    results+=("FAIL	Synapse client versions HTTPS")
    fail=1
  fi

  nc_d="$(nextcloud_domain "$TWS_DOMAIN")"
  nc_path="${TWS_NEXTCLOUD_PATH:-/nextcloud}"
  pw="$(owner_caldav_password "$owner")"
  selfcheck_https_curl_opts "$nc_d"
  tmpcode="$(caldav_propfind_check "$nc_d" "$owner" "$pw" "$nc_path")"
  if [[ "$tmpcode" == "207" ]]; then
    results+=("PASS	CalDAV PROPFIND HTTP 207")
  else
    results+=("FAIL	CalDAV PROPFIND HTTP ${tmpcode}")
    fail=1
  fi

  install_log "--- Self-check results ---"
  local r
  for r in "${results[@]}"; do
    install_log "$r"
    printf '%s\n' "$r"
  done
  install_log "Secrets directory: $(tinyweb_secrets_dir) (back up install.env, mobilizon-admin.password, synapse-admin.password)"
  printf '\nBack up %s, %s/mobilizon-admin.password, and %s/synapse-admin.password regularly.\n' \
    "$(tinyweb_install_env_path)" "$(tinyweb_secrets_dir)" "$(tinyweb_secrets_dir)"

  step_done 10
  if [[ "$fail" -ne 0 ]]; then
    die "Self-check reported failures"
  fi
}

print_dry_run_plan() {
  log "DRY_RUN install plan (no changes):"
  local s
  for s in "${INSTALL_STEPS[@]}"; do
    log "  ${s}"
  done
  log "Config summary:"
  tinyweb_config_summary_lines | while read -r line; do
    log "  ${line}"
  done
  if [[ "$LOCATION_APP" == "owntracks" ]]; then
    log "  (plan will not install traccar)"
  fi
}

main() {
  local cfg _xt=0
  cfg="$(resolve_config_path)"
  [[ $- == *x* ]] && _xt=1
  set +x
  load_tinyweb_env_file "$cfg"
  apply_tinyweb_env_defaults

  if [[ "$INSTALL_DRY_RUN" -eq 1 ]]; then
    if ((_xt)); then set -x; fi
    print_dry_run_plan
    exit 0
  fi

  step_preflight
  step_swapfile
  step_bootstrap
  step_tls
  step_family_apps
  step_matrix_users
  step_family_init
  step_family_seeds
  step_mobilizon_password
  step_federation_sync
  step_selfcheck
  if ((_xt)); then set -x; fi
  install_log "tinywebStack install finished for ${TWS_DOMAIN}"
}

if [[ -z "${TWS_INSTALL_NO_MAIN:-}" ]]; then
  main "$@"
fi
