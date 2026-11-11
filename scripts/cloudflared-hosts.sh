#!/usr/bin/env bash
# Add or remove jellyfin.<family> on the tunnel issued at setup.
#
# Authenticates with the claim token in cloudflared/claim-token. It does not
# read the setup code. Then it re-runs cloudflared-apply.sh, which refuses
# unless the handoff says published is exactly true.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

JELLYFIN=""
DEST_DIR="${TWS_SETUP_CLOUDFLARED_DEST:-}"

usage() {
  cat <<'EOF'
Usage: cloudflared-hosts.sh --jellyfin 0|1 [--dest-dir <dir>]

Updates the existing family tunnel, then runs cloudflared-apply.sh.
Uses the claim token from setup. Does not read the setup code.
Apply refuses unless the handoff says published is exactly true.

--jellyfin 1   Add jellyfin.<family> (proxied CNAME and ingress).
--jellyfin 0   Remove that host.
--dest-dir     Passed through to cloudflared-apply.sh. Tests and image builds.

If cloudflared/handoff.json is missing, this exits 0 and does not call the
control plane. First boot issues the tunnel after install, and that call
already includes Jellyfin when TWS_JELLYFIN=1.

TWS_CONTROL_PLANE_URL overrides cloudflared/control-plane.url. If neither is
set, the default is https://tinyweb.win. TWS_ETC_DIR defaults to /etc/tinywebstack.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jellyfin)
      [[ $# -ge 2 ]] || die "Missing value for --jellyfin"
      JELLYFIN=$2
      shift 2
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

case "$JELLYFIN" in
  0|1) ;;
  *) die "Pass --jellyfin 0 or --jellyfin 1" ;;
esac

ETC="${TWS_ETC_DIR:-/etc/tinywebstack}"
HANDOFF="${ETC}/cloudflared/handoff.json"
CLAIM="${ETC}/cloudflared/claim-token"
APPLY="${SCRIPT_DIR}/cloudflared-apply.sh"
SETUP_PATH="${SCRIPT_DIR}/setup"

if [[ ! -f "$HANDOFF" ]]; then
  log "No tunnel handoff yet. The family tunnel is unchanged."
  exit 0
fi
if [[ ! -f "$CLAIM" ]]; then
  die "The tunnel handoff is present but the claim token is missing. Refusing to change DNS."
fi
if [[ ! -f "$APPLY" ]]; then
  die "Missing cloudflared-apply.sh. Refusing to change DNS."
fi

URL="${TWS_CONTROL_PLANE_URL:-}"
if [[ -z "$URL" && -f "${ETC}/cloudflared/control-plane.url" ]]; then
  URL="$(tr -d '[:space:]' < "${ETC}/cloudflared/control-plane.url")"
fi
if [[ -z "$URL" ]]; then
  URL="https://tinyweb.win"
fi

log "Updating the family tunnel for Jellyfin."
PYTHONPATH="${SETUP_PATH}${PYTHONPATH:+:$PYTHONPATH}" python3 - "$URL" "$CLAIM" "$HANDOFF" "$JELLYFIN" <<'PY'
import json
import os
import sys
from pathlib import Path

from tinyweb_setup.control_plane import ControlPlaneClient, ControlPlaneError

url, claim_path, handoff_path, flag = sys.argv[1:5]
token = Path(claim_path).read_text(encoding="utf-8").strip()
if not token:
    sys.stderr.write("The claim token file is empty. Refusing to change the tunnel.\n")
    sys.exit(1)
try:
    handoff = ControlPlaneClient(url).update_hosts(token, jellyfin=flag == "1")
except ControlPlaneError as exc:
    sys.stderr.write(
        "The control plane refused the tunnel update (%s). No public hostname was published.\n"
        % (exc.code or "error")
    )
    sys.exit(1)
if not isinstance(handoff, dict):
    sys.stderr.write("The control plane returned a response TinyWeb could not read.\n")
    sys.exit(1)
path = Path(handoff_path)
path.parent.mkdir(parents=True, exist_ok=True)
temporary = path.with_name(path.name + ".tmp")
fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(handoff, handle)
    handle.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
os.chmod(path, 0o600)
published = "true" if handoff.get("published") is True else "false"
host = "absent"
for row in handoff.get("dns") or []:
    name = row.get("name") if isinstance(row, dict) else ""
    if isinstance(name, str) and name.startswith("jellyfin."):
        host = "present"
        break
sys.stdout.write("published=%s\n" % published)
sys.stdout.write("jellyfin_host=%s\n" % host)
PY

apply_args=(--credentials "$HANDOFF")
if [[ -n "$DEST_DIR" ]]; then
  apply_args+=(--dest-dir "$DEST_DIR")
fi
bash "$APPLY" "${apply_args[@]}"
