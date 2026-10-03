#!/usr/bin/env bash
# On-box install secrets (/etc/tinywebstack/secrets/install.env). Never log values.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/lib/secrets.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets.sh"
# shellcheck source=scripts/lib/family_users.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/family_users.sh"

tinyweb_secrets_dir() {
  printf '%s\n' "${TWS_ETC_DIR:-/etc/tinywebstack}/secrets"
}

tinyweb_install_env_path() {
  printf '%s\n' "${TINYWEB_INSTALL_ENV:-$(tinyweb_secrets_dir)/install.env}"
}

ensure_tinyweb_secrets_dir() {
  local d
  d="$(tinyweb_secrets_dir)"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: would mkdir -p ${d} (mode 700)"
    return 0
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    install -d -m 700 -o root -g root "$d"
  else
    mkdir -p "$d"
    chmod 700 "$d"
  fi
}

# Read one KEY=value from install.env (%q-quoted on disk; no logging).
read_install_secret() {
  local key=$1
  local f
  f="$(tinyweb_install_env_path)"
  [[ -f "$f" ]] || return 1
  (
    set -a
    # shellcheck source=/dev/null
    source "$f"
    set +a
    if [[ -z "${!key+x}" ]]; then
      exit 1
    fi
    printf '%s' "${!key}"
  )
}

write_install_secret_merge() {
  local key=$1
  local value=$2
  local f d old_umask
  f="$(tinyweb_install_env_path)"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: would set ${key} in ${f}"
    return 0
  fi
  ensure_tinyweb_secrets_dir
  d="$(tinyweb_secrets_dir)"
  old_umask="$(umask)"
  (
    umask 077
    local tmp
    tmp="$(mktemp "${d}/.install.env.tmp.XXXXXX")"
    trap 'rm -f "${tmp:-}"' EXIT
    if [[ -f "$f" ]]; then
      grep -Ev "^${key}=" "$f" >"$tmp" || true
    fi
    printf '%s=%q\n' "$key" "$value" >>"$tmp"
    if [[ "$(id -u)" -eq 0 ]]; then
      install -m 600 -o root -g root "$tmp" "$f"
    else
      install -m 600 "$tmp" "$f"
    fi
  )
  umask "$old_umask"
}

generate_install_password() {
  if [[ -n "${LAB_PASSWORD:-}" ]]; then
    generate_test_password
    return 0
  fi
  local pw=""
  while [[ ${#pw} -lt 24 ]]; do
    pw+="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c $((24 - ${#pw})))"
  done
  printf '%s' "$pw"
}

ensure_install_secret() {
  local key=$1
  local existing
  existing="$(read_install_secret "$key" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    return 0
  fi
  write_install_secret_merge "$key" "$(generate_install_password)"
}

ensure_tinyweb_install_secrets() {
  local main_domain=$1
  local mode=$2
  local location_app=$3
  local -a family_users=()
  local u

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: would ensure install.env secrets (mode=${mode})"
    return 0
  fi

  local _xt=0
  [[ $- == *x* ]] && _xt=1
  set +x
  ensure_install_secret YUNOHOST_ADMIN_PASSWORD
  if [[ -z "$(read_install_secret MOBILIZON_ADMIN_PASSWORD 2>/dev/null || true)" ]]; then
    write_install_secret_merge MOBILIZON_ADMIN_PASSWORD "$(read_install_secret YUNOHOST_ADMIN_PASSWORD)"
  fi
  ensure_install_secret PARENT_PASSWORD
  ensure_install_secret KID_PASSWORD

  if [[ "$mode" == "lab" ]]; then
    ensure_install_secret ALICE_PASSWORD
    ensure_install_secret BOB_PASSWORD
  fi

  if [[ "$location_app" == "traccar" ]]; then
    ensure_install_secret TRACCAR_ADMIN_PASSWORD
    if [[ -z "$(read_install_secret TRACCAR_ADMIN_LOGIN 2>/dev/null || true)" ]]; then
      write_install_secret_merge TRACCAR_ADMIN_LOGIN "admin@${main_domain}"
    fi
  fi

  if [[ -n "${TWS_FAMILY_USERS:-}" ]]; then
    IFS=',' read -r -a family_users <<<"$TWS_FAMILY_USERS"
    for u in "${family_users[@]}"; do
      u="${u#"${u%%[![:space:]]*}"}"
      u="${u%"${u##*[![:space:]]}"}"
      [[ -z "$u" ]] && continue
      case "$u" in alice|bob|parent|kid) continue ;; esac
      ensure_install_secret "$(test_password_env_key "$u")"
    done
  fi

  {
    local f
    f="$(tinyweb_install_env_path)"
    if [[ -f "$f" ]]; then
      grep -q '^TW_STACK_SECRETS_SOURCE=local' "$f" || \
        printf '%s\n' 'TW_STACK_SECRETS_SOURCE=local' >>"$f"
      grep -q '^TW_STACK_IS_REMOTE=1' "$f" || \
        printf '%s\n' 'TW_STACK_IS_REMOTE=1' >>"$f"
      chmod 600 "$f"
    fi
  }
  if ((_xt)); then set -x; fi
}

source_tinyweb_install_env() {
  local f _xt=0
  f="$(tinyweb_install_env_path)"
  [[ -f "$f" ]] || die "Missing install secrets at ${f} (run secrets step first)"
  [[ $- == *x* ]] && _xt=1
  set +x
  set -a
  # shellcheck source=/dev/null
  source "$f"
  set +a
  if ((_xt)); then set -x; fi
}
