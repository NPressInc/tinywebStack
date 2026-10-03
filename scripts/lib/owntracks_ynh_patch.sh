#!/usr/bin/env bash
# Patch owntracks_ynh manifest.toml when upstream apt GPG key URL is broken (fresh install).
set -euo pipefail

owntracks_ynh_legacy_apt_key_url() {
  printf '%s\n' "https://raw.githubusercontent.com/owntracks/recorder/master/etc/repo.owntracks.org.gpg.key"
}

owntracks_ynh_default_apt_key_url() {
  printf '%s\n' "${OWNTRACKS_APT_KEY_URL:-https://raw.githubusercontent.com/owntracks/recorder/master/etc/repo-v2.owntracks.org.gpg.key}"
}

owntracks_ynh_legacy_key_url_http_ok() {
  local url=$1
  local code
  code="$(curl -fsI -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")"
  [[ "$code" == "200" ]]
}

# Rewrite legacy apt key URL in manifest when the legacy URL is unreachable. Idempotent.
owntracks_ynh_patch_manifest_if_needed() {
  local manifest=$1
  local key_url=${2:-$(owntracks_ynh_default_apt_key_url)}
  local legacy=${3:-$(owntracks_ynh_legacy_apt_key_url)}

  [[ -f "$manifest" ]] || return 0
  grep -qF "$legacy" "$manifest" || return 0
  if owntracks_ynh_legacy_key_url_http_ok "$legacy"; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  sed "s#${legacy}#${key_url}#g" "$manifest" >"$tmp"
  mv "$tmp" "$manifest"
  if declare -F log >/dev/null 2>&1; then
    log "WARN: upstream owntracks_ynh manifest.toml apt key URL was patched (legacy key URL is not HTTP 200)"
  else
    printf '[tinywebstack] WARN: upstream owntracks_ynh manifest.toml apt key URL was patched (legacy key URL is not HTTP 200)\n' >&2
  fi
}

OWNTRACKS_YNH_CLONE_TMP=""

owntracks_ynh_cleanup_clone() {
  if [[ -n "${OWNTRACKS_YNH_CLONE_TMP}" && -d "${OWNTRACKS_YNH_CLONE_TMP}" ]]; then
    rm -rf "${OWNTRACKS_YNH_CLONE_TMP}"
  fi
  OWNTRACKS_YNH_CLONE_TMP=""
}

owntracks_ynh_ensure_git() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi
  apt-get update -qq >&2
  apt-get install -y -qq git >&2
}

# shellcheck disable=SC2034  # read by scripts that source this library
OWNTRACKS_YNH_INSTALL_SRC=""

# Set OWNTRACKS_YNH_INSTALL_SRC to a local clone (patched manifest) or app_url on failure.
# Caller must register EXIT cleanup (owntracks_ynh_cleanup_clone) and remove the clone after install.
owntracks_ynh_resolve_install_source() {
  local app_url=$1
  local src_dir key_url

  OWNTRACKS_YNH_INSTALL_SRC="$app_url"
  key_url="$(owntracks_ynh_default_apt_key_url)"

  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi

  OWNTRACKS_YNH_CLONE_TMP="$(mktemp -d)"

  if ! owntracks_ynh_ensure_git; then
    if declare -F log >/dev/null 2>&1; then
      log "WARN: git unavailable for owntracks_ynh clone; installing from URL"
    fi
    owntracks_ynh_cleanup_clone
    return 0
  fi

  src_dir="${OWNTRACKS_YNH_CLONE_TMP}/owntracks_ynh_src"
  if ! git clone --depth 1 "$app_url" "$src_dir" >&2; then
    if declare -F log >/dev/null 2>&1; then
      log "WARN: git clone of owntracks_ynh failed; installing from URL"
    fi
    owntracks_ynh_cleanup_clone
    return 0
  fi

  owntracks_ynh_patch_manifest_if_needed "${src_dir}/manifest.toml" "$key_url"
  # shellcheck disable=SC2034
  OWNTRACKS_YNH_INSTALL_SRC="$src_dir"
}
