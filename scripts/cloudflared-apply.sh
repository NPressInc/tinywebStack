#!/usr/bin/env bash
# Apply a TinyWeb control-plane tunnel handoff on the home box.
#
# Standalone installer hook. First-boot setup can call this after it saves the
# POST /v1/tunnels JSON. scripts/install-tinyweb.sh does not call it.
#
# This script does not create DNS. It refuses to start cloudflared when the
# credentials are missing or when the control plane says it did not publish.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

CREDENTIALS=""
DRY_RUN=0
DEST_DIR=""

usage() {
  cat <<'EOF'
Usage: cloudflared-apply.sh --credentials <handoff.json> [--dry-run] [--dest-dir <dir>]

--credentials  Handoff JSON from POST /v1/tunnels. The token may be top-level or under "tunnel".
--dry-run      Validate only. Prints a plan and does not write or start cloudflared.
--dest-dir     Write tunnel.env and the systemd unit here, and do not run systemctl.

Missing or unpublished credentials fail. This script never creates a public DNS name.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --credentials)
      [[ $# -ge 2 ]] || die "Missing value for --credentials"
      CREDENTIALS=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --dest-dir)
      [[ $# -ge 2 ]] || die "Missing value for --dest-dir"
      DEST_DIR=$2
      shift 2
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

if [[ -z "$CREDENTIALS" || ! -f "$CREDENTIALS" ]]; then
  die "Cloudflare tunnel credentials are missing${CREDENTIALS:+ (${CREDENTIALS})}. Refusing to publish a public hostname."
fi

info_file="$(mktemp)"
trap 'rm -f "$info_file"' EXIT

read_handoff() {
  local mode=$1
  local env_out=$2
  if ! python3 - "$CREDENTIALS" "$mode" "$env_out" >"$info_file" <<'PY'
import json, os, re, sys

path, mode, env_out = sys.argv[1], sys.argv[2], sys.argv[3]

def fail(message):
    sys.stderr.write(message.rstrip() + "\n")
    sys.exit(1)

try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except FileNotFoundError:
    fail("Cloudflare tunnel credentials are missing. Refusing to publish a public hostname.")
except json.JSONDecodeError:
    fail("Cloudflare tunnel credentials file is not valid JSON. Refusing to publish a public hostname.")

if not isinstance(data, dict):
    fail("Cloudflare tunnel credentials file is not a JSON object. Refusing to publish a public hostname.")

tunnel = data.get("tunnel") if isinstance(data.get("tunnel"), dict) else {}
token = data.get("token") or tunnel.get("token") or ""
tunnel_id = data.get("tunnel_id") or tunnel.get("tunnel_id") or ""
if not isinstance(token, str) or not isinstance(tunnel_id, str):
    fail("Cloudflare tunnel credentials file has no token. Refusing to publish a public hostname.")
token = token.strip()
tunnel_id = tunnel_id.strip()
if not token or any(char in token for char in "\r\n\x00 "):
    fail("Cloudflare tunnel credentials file has no token. Refusing to publish a public hostname.")
if not re.fullmatch(r"[A-Za-z0-9_-]{8,80}", tunnel_id):
    fail("Cloudflare tunnel credentials file has no tunnel id. Refusing to publish a public hostname.")

published = "unset"
if "published" in data:
    if data["published"] is True:
        published = "true"
    else:
        fail(
            "Refusing to publish a public hostname: the control plane marked these "
            "credentials published=false."
        )

if mode == "write":
    parent = os.path.dirname(env_out)
    if not parent:
        fail("Refusing to publish a public hostname: no destination for the tunnel token.")
    os.makedirs(parent, mode=0o700, exist_ok=True)
    os.chmod(parent, 0o700)
    fd = os.open(env_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("TUNNEL_TOKEN=%s\n" % token)
    os.chmod(env_out, 0o600)

sys.stdout.write("tunnel_id=%s\n" % tunnel_id)
sys.stdout.write("published=%s\n" % published)
PY
  then
    exit 1
  fi
}

read_handoff check ""
tunnel_id=""
published=""
while IFS='=' read -r key value; do
  case "$key" in
    tunnel_id) tunnel_id=$value ;;
    published) published=$value ;;
  esac
done <"$info_file"

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'tunnel_id=%s\n' "$tunnel_id"
  printf 'published=%s\n' "$published"
  printf 'service_started=no\n'
  printf 'dns_changed=no\n'
  log "Dry run only (tunnel_id=${tunnel_id}). cloudflared was not started and DNS was not changed."
  exit 0
fi

if [[ -n "$DEST_DIR" ]]; then
  ENV_OUT="${DEST_DIR}/tunnel.env"
  UNIT_OUT="${DEST_DIR}/tinyweb-cloudflared.service"
else
  [[ "$(id -u)" -eq 0 ]] || die "cloudflared-apply.sh must run as root (or pass --dest-dir to stage files). Refusing to publish a public hostname."
  command -v cloudflared >/dev/null 2>&1 || die "cloudflared is not installed. Run scripts/cloudflared-install.sh. Refusing to publish a public hostname."
  ENV_OUT=/etc/tinywebstack/cloudflared/tunnel.env
  UNIT_OUT=/etc/systemd/system/tinyweb-cloudflared.service
fi

if [[ -z "$DEST_DIR" ]]; then
  CLOUDFLARED_BIN="$(command -v cloudflared)"
else
  CLOUDFLARED_BIN="$(command -v cloudflared 2>/dev/null || true)"
  CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/bin/cloudflared}"
fi
case "$CLOUDFLARED_BIN" in
  *" "*|*"'"*)
    die "cloudflared path is not usable. Refusing to publish a public hostname."
    ;;
esac

read_handoff write "$ENV_OUT"

python3 - "$UNIT_OUT" "$ENV_OUT" "$CLOUDFLARED_BIN" <<'PY'
import os, sys
unit_path, env_path, binary = sys.argv[1], sys.argv[2], sys.argv[3]
parent = os.path.dirname(unit_path)
if parent:
    os.makedirs(parent, exist_ok=True)
content = """[Unit]
Description=TinyWeb Cloudflare Tunnel (outbound only)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=%s
ExecStart=%s tunnel --no-autoupdate run
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
""" % (env_path, binary)
with open(unit_path, "w", encoding="utf-8") as handle:
    handle.write(content)
os.chmod(unit_path, 0o644)
PY

if [[ -n "$DEST_DIR" ]]; then
  printf 'tunnel_id=%s\n' "$tunnel_id"
  printf 'published=%s\n' "$published"
  printf 'service_started=no\n'
  printf 'dns_changed=no\n'
  log "Staged cloudflared unit in ${DEST_DIR} (tunnel_id=${tunnel_id}). DNS was not changed."
  exit 0
fi

systemctl daemon-reload
systemctl enable --now tinyweb-cloudflared.service
printf 'tunnel_id=%s\n' "$tunnel_id"
printf 'published=%s\n' "$published"
printf 'service_started=yes\n'
printf 'dns_changed=no\n'
log "Enabled tinyweb-cloudflared.service (tunnel_id=${tunnel_id}). DNS is managed by the control plane."
