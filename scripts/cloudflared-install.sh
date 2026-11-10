#!/usr/bin/env bash
# Install cloudflared on a TinyWeb home box.
#
# Does not read tunnel credentials, start a tunnel, or publish a hostname.
# After the control plane issues a token, run scripts/cloudflared-apply.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: cloudflared-install.sh [--dry-run]

Installs the cloudflared package from Cloudflare's apt repository.
Does not start a tunnel and does not create DNS records.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if command -v cloudflared >/dev/null 2>&1; then
  log "cloudflared already installed: $(command -v cloudflared)"
  log "Not starting a tunnel and not publishing a hostname."
  exit 0
fi

log "Would add the Cloudflare apt repository https://pkg.cloudflare.com/cloudflared and install cloudflared."
log "Not starting a tunnel and not publishing a hostname."
if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || die "cloudflared-install.sh must run as root"
require_cmd curl

install -d -m 0755 /usr/share/keyrings
key_tmp="$(mktemp)"
trap 'rm -f "$key_tmp"' EXIT
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o "$key_tmp"
install -m 0644 "$key_tmp" /usr/share/keyrings/cloudflare-main.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
  >/etc/apt/sources.list.d/cloudflared.list
apt-get update
apt-get install -y cloudflared
log "Installed cloudflared. No tunnel was started. Next: scripts/cloudflared-apply.sh --credentials <handoff.json>"
