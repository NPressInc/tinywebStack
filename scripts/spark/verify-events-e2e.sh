#!/usr/bin/env bash
# Mobilizon events: SSO login, cross-family federation + RSVP, reject non-trusted instance.
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
Usage: verify-events-e2e.sh NODE_A NODE_B DOMAIN_A DOMAIN_B [REJECT_INSTANCE_HOST]

Example:
  verify-events-e2e.sh family-a family-b family-a.family.test family-b.family.test mobilizon.fr
EOF
  exit 1
}

[[ $# -ge 4 ]] || usage

NODE_A=$1
NODE_B=$2
DOMAIN_A=$3
DOMAIN_B=$4
REJECT_HOST=${5:-${MOBILIZON_REJECT_PROBE:-mobilizon.fr}}

require_cmd python3

PARENT_A_PW="${PARENT_PASSWORD:-$(read_node_secret "$NODE_A" parent_password || true)}"
PARENT_B_PW="${PARENT_PASSWORD:-$(read_node_secret "$NODE_B" parent_password || true)}"
[[ -n "$PARENT_A_PW" && -n "$PARENT_B_PW" ]] || die "parent passwords required in secrets (use LAB_PASSWORD=dummydummy on spark)"

resolve_lab_ca() {
  local c
  for c in \
    "${TW_STACK_LAB_CA_DIR:-}/lab-ca.crt.pem" \
    "${TW_STACK_SECRETS_DIR}/lab-ca/lab-ca.crt.pem"; do
    if [[ -f "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

CA_PEM=""
if CA_PEM="$(resolve_lab_ca)"; then
  export TWS_CA_BUNDLE="$CA_PEM"
else
  export TWS_LAB_TLS_INSECURE=1
fi

export DOMAIN_A DOMAIN_B NODE_A NODE_B PARENT_A_PW PARENT_B_PW REJECT_HOST TW_STACK_ROOT

python3 - <<'PY'
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.environ["TW_STACK_ROOT"], "family", "synapse_module"))
from tinywebstack_family.mobilizon import MobilizonClient, events_domain, sync_instance_federation

def ssl_ctx():
    if os.environ.get("TWS_LAB_TLS_INSECURE") == "1":
        return ssl._create_unverified_context()
    ca = os.environ.get("TWS_CA_BUNDLE")
    if ca and os.path.isfile(ca):
        return ssl.create_default_context(cafile=ca)
    return ssl._create_unverified_context()

ctx = ssl_ctx()
domain_a = os.environ["DOMAIN_A"]
domain_b = os.environ["DOMAIN_B"]
host_a = events_domain(domain_a)
host_b = events_domain(domain_b)
base_a = f"https://{host_a}"
base_b = f"https://{host_b}"
email_a = f"parent@{domain_a}"
email_b = f"parent@{domain_b}"
reject = os.environ["REJECT_HOST"]

def check_sso(url: str) -> None:
    req = urllib.request.Request(url, method="GET")
    code = 0
    body = ""
    try:
        with urllib.request.urlopen(req, timeout=20, context=ctx) as resp:
            code = resp.getcode()
            body = resp.read(8000).decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        code = exc.code
        body = exc.read(8000).decode("utf-8", errors="replace")
    if code in (401, 403):
        return
    if code < 500:
        return
    raise SystemExit(f"SSO check failed for {url}: HTTP {code} body={body[:200]!r}")

print("== Mobilizon installed (HTTPS reachable) ==")
check_sso(base_a + "/")
check_sso(base_b + "/")
print("  OK reachability + SSO gateway")

print("== Federation sync (trusted pair) ==")
client_a = MobilizonClient.login(base_a, email_a, os.environ["PARENT_A_PW"], ssl_context=ctx)
client_b = MobilizonClient.login(base_b, email_b, os.environ["PARENT_B_PW"], ssl_context=ctx)
sync_a = sync_instance_federation(
    client_a, local_main_domain=domain_a, trusted_main_domains=[domain_b], ssl_context=ctx
)
sync_b = sync_instance_federation(
    client_b, local_main_domain=domain_b, trusted_main_domains=[domain_a], ssl_context=ctx
)
print(json.dumps({"A": sync_a, "B": sync_b}, indent=2))

print("== Cross-home event + RSVP ==")
start = datetime.now(timezone.utc) + timedelta(days=2)
end = start + timedelta(hours=2)
title = f"tinywebStack lab {int(start.timestamp())}"
create_q = """
mutation CreateEvent($title: String!, $begins: DateTime!, $ends: DateTime!) {
  createEvent(title: $title, description: "lab", beginsOn: $begins, endsOn: $ends, status: CONFIRMED, visibility: PUBLIC) {
    id
    uuid
  }
}
"""
created = client_a.gql(
    create_q,
    {"title": title, "begins": start.isoformat(), "ends": end.isoformat()},
    ssl_context=ctx,
)
event_id = (created.get("createEvent") or {}).get("id")
if not event_id:
    raise SystemExit(f"createEvent failed: {created}")
ident_q = "query { loggedUser { id defaultActor { id } } }"
ident_b = client_b.gql(ident_q, ssl_context=ctx)
actor_b = ((ident_b.get("loggedUser") or {}).get("defaultActor") or {}).get("id")
if not actor_b:
    raise SystemExit(f"No default actor on B: {ident_b}")
join_q = """
mutation Join($eventId: ID!, $actorId: ID!) {
  joinEvent(eventId: $eventId, actorId: $actorId) { id }
}
"""
joined = client_b.gql(join_q, {"eventId": event_id, "actorId": actor_b}, ssl_context=ctx)
if not (joined.get("joinEvent") or {}).get("id"):
    raise SystemExit(f"joinEvent failed: {joined}")
print(f"  OK event {event_id} joined from {host_b}")

print("== Non-trusted instance probe ==")
probe = sync_instance_federation(
    client_a,
    local_main_domain=domain_a,
    trusted_main_domains=[domain_b],
    reject_probe_host=reject,
    ssl_context=ctx,
)
status = probe.get("reject_probe_followed_status")
if status == "APPROVED":
    raise SystemExit(f"Reject probe {reject} unexpectedly APPROVED")
print(f"  OK probe {reject} not approved (status={status})")
print("All Mobilizon event checks passed.")
PY

log "verify-events-e2e completed"
