#!/usr/bin/env bash
# Prepare OwnTracks apt repo (current signing key + signed-by) before owntracks_ynh.
# Idempotent; falls back to direct .deb install when apt still fails.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

KEY_URL="${OWNTRACKS_APT_KEY_URL:-https://raw.githubusercontent.com/owntracks/recorder/master/etc/repo-v2.owntracks.org.gpg.key}"
LEGACY_KEY_URL="https://raw.githubusercontent.com/owntracks/recorder/master/etc/repo.owntracks.org.gpg.key"
KEY_ASC="/etc/apt/trusted.gpg.d/owntracks.asc"
KEYRING="/usr/share/keyrings/owntracks-archive-keyring.gpg"
REPO_URI="http://repo.owntracks.org/debian/"
SOURCES_DEB822="/etc/apt/sources.list.d/owntracks-tinywebstack.sources"
PACKAGE="ot-recorder"

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

fetch_key() {
  local url=$1 dest=$2
  local tmp
  tmp="$(mktemp)"
  curl -fsSL "$url" -o "$tmp"
  grep -q "BEGIN PGP" "$tmp" || die "Downloaded key from ${url} does not look like a PGP key"
  install -m 644 "$tmp" "$dest"
  rm -f "$tmp"
}

install_keys() {
  fetch_key "$KEY_URL" "$KEY_ASC"
  gpg --dearmor --yes -o "$KEYRING" "$KEY_ASC" 2>/dev/null || cp "$KEY_ASC" "$KEYRING"
  log "Installed OwnTracks apt key → ${KEY_ASC} and ${KEYRING}"
}

write_sources() {
  local suite=$1
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
Types: deb
URIs: ${REPO_URI}
Suites: ${suite}
Components: main
Signed-By: ${KEY_ASC}
EOF
  if [[ -f "$SOURCES_DEB822" ]] && cmp -s "$tmp" "$SOURCES_DEB822"; then
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$SOURCES_DEB822"
  log "Wrote ${SOURCES_DEB822} (suite=${suite})"
}

patch_ynh_list_if_needed() {
  # owntracks_ynh manifest uses the legacy key URL; ensure any list uses Signed-By: owntracks.asc
  local f
  for f in /etc/apt/sources.list.d/owntracks.list /etc/apt/sources.list.d/owntracks*.list; do
    [[ -f "$f" ]] || continue
    if grep -q "repo.owntracks.org" "$f" && ! grep -q "signed-by" "$f"; then
      sed -i 's|^deb |deb [signed-by='"${KEY_ASC}"'] |' "$f" || true
      log "Patched signed-by in ${f}"
    fi
  done
}

try_apt_install() {
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$PACKAGE"
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
  dpkg -i "$tmpdeb" || apt-get install -f -y -qq
  rm -f "$tmpdeb"
  log "Installed ${PACKAGE} from ${deb_url}"
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if dpkg -s "$PACKAGE" >/dev/null 2>&1; then
  log "${PACKAGE} already installed"
  exit 0
fi

install_keys
write_sources "$(debian_suite)"
patch_ynh_list_if_needed

if try_apt_install; then
  log "${PACKAGE} installed via apt"
  exit 0
fi

log "apt install ${PACKAGE} failed; trying legacy key"
fetch_key "$LEGACY_KEY_URL" "$KEY_ASC"
gpg --dearmor --yes -o "$KEYRING" "$KEY_ASC" 2>/dev/null || true
if try_apt_install; then
  log "${PACKAGE} installed via apt (legacy key)"
  exit 0
fi

install_deb_fallback
