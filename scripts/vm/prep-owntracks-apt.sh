#!/usr/bin/env bash
# Prepare OwnTracks apt signing key before owntracks_ynh (avoid Signed-By conflicts).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

KEY_URL="${OWNTRACKS_APT_KEY_URL:-https://raw.githubusercontent.com/owntracks/recorder/master/etc/repo-v2.owntracks.org.gpg.key}"
LEGACY_KEY_URL="https://raw.githubusercontent.com/owntracks/recorder/master/etc/repo.owntracks.org.gpg.key"
KEY_GPG="${OWNTRACKS_APT_KEY_GPG:-/etc/apt/trusted.gpg.d/owntracks.gpg}"
PACKAGE="ot-recorder"
REPO_URI="http://repo.owntracks.org/debian/"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

require_cmd curl gpg apt-get dpkg

debian_suite() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "${VERSION_CODENAME:-bookworm}"
  else
    echo bookworm
  fi
}

debian_arch() {
  dpkg --print-architecture
}

install_apt_key() {
  local url=$1
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL "$url" -o "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! grep -q "BEGIN PGP" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  gpg --dearmor --yes -o "$KEY_GPG" "$tmp"
  rm -f "$tmp"
  chmod 644 "$KEY_GPG"
  rm -f /etc/apt/trusted.gpg.d/owntracks.asc
  log "Installed dearmored OwnTracks apt key at ${KEY_GPG}"
}

remove_conflicting_sources() {
  rm -f /etc/apt/sources.list.d/owntracks-tinywebstack.sources
}

try_apt_install() {
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$PACKAGE"
}

install_deb_fallback() {
  local suite arch deb_url tmpdeb
  suite="$(debian_suite)"
  arch="$(debian_arch)"
  log "Attempting direct .deb install for ${PACKAGE} (${suite}/${arch})"
  tmpdeb="$(mktemp --suffix=.deb)"
  deb_url="$(
    curl -fsSL "${REPO_URI}dists/${suite}/main/binary-${arch}/Packages" \
      | awk -v pkg="$PACKAGE" '
        $1 == "Package:" && $2 == pkg { found=1 }
        found && $1 == "Filename:" { print $2; exit }
      '
  )"
  [[ -n "$deb_url" ]] || die "Could not resolve ${PACKAGE} .deb for ${suite}/${arch}"
  curl -fsSL "${REPO_URI}${deb_url}" -o "$tmpdeb"
  dpkg -i "$tmpdeb" || apt-get install -f -y
  rm -f "$tmpdeb"
  log "Installed ${PACKAGE} from ${deb_url}"
}

if dpkg -s "$PACKAGE" >/dev/null 2>&1; then
  log "${PACKAGE} already installed"
  exit 0
fi

remove_conflicting_sources
install_apt_key "$KEY_URL" || die "Could not install OwnTracks apt key from ${KEY_URL}"

if try_apt_install; then
  log "${PACKAGE} installed via apt"
  exit 0
fi

log "apt install ${PACKAGE} failed; trying legacy key"
if install_apt_key "$LEGACY_KEY_URL"; then
  if try_apt_install; then
    log "${PACKAGE} installed via apt (legacy key)"
    exit 0
  fi
else
  log "WARN: could not install legacy OwnTracks apt key from ${LEGACY_KEY_URL}; continuing to .deb fallback"
fi

install_deb_fallback
