#!/usr/bin/env bash
# End-to-end Matrix federation check via Client-Server API.
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_script_dir}/../lib/common.sh" ]]; then
  TW_STACK_ROOT="$(cd "${_script_dir}/.." && pwd)"
  # shellcheck source=scripts/lib/common.sh
  source "${TW_STACK_ROOT}/lib/common.sh"
  # shellcheck source=scripts/lib/secrets.sh
  source "${TW_STACK_ROOT}/lib/secrets.sh"
else
  TW_STACK_ROOT="$(cd "${_script_dir}/../.." && pwd)"
  # shellcheck source=scripts/lib/common.sh
  source "${TW_STACK_ROOT}/scripts/lib/common.sh"
  # shellcheck source=scripts/lib/secrets.sh
  source "${TW_STACK_ROOT}/scripts/lib/secrets.sh"
fi
load_config
load_secrets

usage() {
  cat <<'EOF'
Usage: verify-federation-e2e.sh \
  NODE_A NODE_B DOMAIN_A DOMAIN_B ALICE_USER BOB_USER [REJECT_SERVER_DOMAIN]
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

require_cmd python3

ALICE_PASSWORD="${ALICE_PASSWORD:-$(read_node_secret "$NODE_A" alice_password || true)}"
BOB_PASSWORD="${BOB_PASSWORD:-$(read_node_secret "$NODE_B" bob_password || true)}"
[[ -n "$ALICE_PASSWORD" && -n "$BOB_PASSWORD" ]] || \
  die "Set alice/bob passwords in $(secrets_file)"

resolve_lab_ca() {
  local c
  for c in \
    "${TW_STACK_LAB_CA_DIR:-}/lab-ca.crt.pem" \
    "${TW_STACK_ROOT}/lab-certs/lab-ca.crt.pem" \
    "${TW_STACK_SECRETS_DIR:-}/lab-ca/lab-ca.crt.pem"
  do
    if [[ -f "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

LAB_CA="$(resolve_lab_ca)" || die "Lab CA not found (expected under TW_STACK_LAB_CA_DIR or ${TW_STACK_ROOT}/lab-certs/)"

export DOMAIN_A DOMAIN_B ALICE_USER BOB_USER ALICE_PASSWORD BOB_PASSWORD REJECT_DOMAIN LAB_CA

python3 <<'PY'
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

lab_ca = os.environ["LAB_CA"]
if not os.path.isfile(lab_ca):
    sys.exit(f"Lab CA missing: {lab_ca}")

ctx = ssl.create_default_context()
ctx.load_verify_locations(lab_ca)


def req(method, url, token=None, body=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if body is None else json.dumps(body).encode()
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, context=ctx, timeout=90) as resp:
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
room_enc = urllib.parse.quote(room_id, safe="")

join = req("POST", f"https://{db}/_matrix/client/v3/join/{room_enc}", token=b_token, body={})
if "room_id" not in join:
    sys.exit(f"bob join failed: {join}")

msg = f"tinywebstack federation ping {uuid.uuid4()}"
txn = uuid.uuid4().hex
send = req(
    "PUT",
    f"https://{da}/_matrix/client/v3/rooms/{room_enc}/send/m.room.message/{txn}",
    token=a_token,
    body={"msgtype": "m.text", "body": msg},
)
if "event_id" not in send:
    sys.exit(f"send failed: {send}")

found = False
for _ in range(30):
    hist = req(
        "GET",
        f"https://{db}/_matrix/client/v3/rooms/{room_enc}/messages?dir=b&limit=20",
        token=b_token,
    )
    if msg in json.dumps(hist):
        found = True
        break
    time.sleep(2)

if not found:
    sys.exit("Message not visible to bob at /messages — federation failed")

print("OK: bob received federated message")

bad = req(
    "POST",
    f"https://{da}/_matrix/client/v3/createRoom",
    token=a_token,
    body={"invite": [f"@someone:{reject}"], "preset": "private_chat"},
)
if bad.get("errcode") not in ("M_FORBIDDEN", "M_UNKNOWN"):
    sys.exit(f"Expected M_FORBIDDEN inviting {reject}, got: {bad}")
err = bad.get("error", "")
if bad.get("errcode") == "M_FORBIDDEN" and "Federation denied" not in err and "denied" not in err.lower():
    print(f"WARN: expected 'Federation denied' text, got: {err[:120]}")
print(f"OK: invite to {reject} refused ({bad.get('errcode')}: {err[:120]})")
PY

log "Federation verification passed."
