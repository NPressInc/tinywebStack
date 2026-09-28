#!/usr/bin/env bash
# End-to-end Matrix federation check via Client-Server API (run from spark).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/secrets.sh
source "${TW_STACK_ROOT}/scripts/lib/secrets.sh"
load_config

usage() {
  cat <<'EOF'
Usage: verify-federation-e2e.sh \
  NODE_A NODE_B DOMAIN_A DOMAIN_B ALICE_USER BOB_USER [REJECT_SERVER_DOMAIN]

Logs in on both homeservers, federated DM, message delivery, and allowlist rejection.

Passwords via ALICE_PASSWORD / BOB_PASSWORD or TW_STACK_SECRETS_FILE:
  ALICE_PASSWORD_<NODE>, BOB_PASSWORD_<NODE> (uppercase node name).
EOF
  exit 1
}

[[ $# -ge 6 ]] || usage

NODE_A=$1
NODE_B=$2
DOMAIN_A=$3
DOMAIN_B=$4
ALICE_USER=$5
BOB_USER=$6
REJECT_DOMAIN=${7:-matrix.org}

require_cmd curl python3

ALICE_PASSWORD="${ALICE_PASSWORD:-$(read_node_secret "$NODE_A" alice_password || true)}"
BOB_PASSWORD="${BOB_PASSWORD:-$(read_node_secret "$NODE_B" bob_password || true)}"
[[ -n "$ALICE_PASSWORD" && -n "$BOB_PASSWORD" ]] || \
  die "Set ALICE_PASSWORD and BOB_PASSWORD (or secrets file entries)"

export DOMAIN_A DOMAIN_B ALICE_USER BOB_USER ALICE_PASSWORD BOB_PASSWORD REJECT_DOMAIN

python3 <<'PY'
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def req(method, url, token=None, body=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if body is None else json.dumps(body).encode()
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, context=ctx, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"errcode": f"HTTP_{e.code}", "error": raw[:500]}


def login(base, user, password):
    out = req(
        "POST",
        f"{base}/_matrix/client/v3/login",
        body={
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": user},
            "password": password,
            "initial_device_display_name": "tinywebstack-verify",
        },
    )
    if "access_token" not in out:
        sys.exit(f"Login failed for {user} on {base}: {out}")
    return out["access_token"]


da = os.environ["DOMAIN_A"]
db = os.environ["DOMAIN_B"]
alice = os.environ["ALICE_USER"]
bob = os.environ["BOB_USER"]
reject = os.environ["REJECT_DOMAIN"]

a_token = login(f"https://{da}", alice, os.environ["ALICE_PASSWORD"])
b_token = login(f"https://{db}", bob, os.environ["BOB_PASSWORD"])
bob_id = f"@{bob}:{db}"

room = req(
    "POST",
    f"https://{da}/_matrix/client/v3/createRoom",
    token=a_token,
    body={"invite": [bob_id], "is_direct": True, "preset": "trusted_private_chat"},
)
if "room_id" not in room:
    sys.exit(f"createRoom failed: {room}")
room_id = room["room_id"]

msg = f"tinywebstack federation ping {uuid.uuid4()}"
txn = uuid.uuid4().hex
path = f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id, safe='')}/send/m.room.message/{txn}"
send = req("PUT", f"https://{da}{path}", token=a_token, body={"msgtype": "m.text", "body": msg})
if "event_id" not in send:
    sys.exit(f"send failed: {send}")

sync = req("GET", f"https://{db}/_matrix/client/v3/sync?timeout=30000", token=b_token)
if msg not in json.dumps(sync):
    sys.exit("Message not visible to bob — federation or membership failed")
print("OK: bob received federated message")

bad = req(
    "POST",
    f"https://{da}/_matrix/client/v3/createRoom",
    token=a_token,
    body={"invite": [f"@someone:{reject}"], "preset": "private_chat"},
)
if "errcode" not in bad:
    sys.exit(f"Expected allowlist failure inviting {reject}, got: {bad}")
print(f"OK: invite to {reject} refused ({bad.get('errcode')})")
PY

log "Federation verification passed."
