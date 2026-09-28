#!/usr/bin/env bash
# Install current OwnTracks apt signing key before owntracks_ynh (package key is outdated).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
load_config

KEY_URL="${OWNTRACKS_APT_KEY_URL:-https://raw.githubusercontent.com/owntracks/recorder/master/etc/repo-v2.owntracks.org.gpg.key}"
KEY_PATH="/etc/apt/trusted.gpg.d/owntracks-tinywebstack.asc"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

require_cmd curl

TMP="$(mktemp)"
curl -fsSL "$KEY_URL" -o "$TMP"
# Basic sanity: armored OpenPGP block
grep -q "BEGIN PGP" "$TMP" || die "Downloaded key from ${KEY_URL} does not look like a PGP key"

install -m 644 "$TMP" "$KEY_PATH"
rm -f "$TMP"
log "Installed OwnTracks apt key from ${KEY_URL} → ${KEY_PATH}"
