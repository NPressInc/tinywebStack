#!/usr/bin/env bash
# Mobilizon events: federation paths, LDAP login, cross-family RSVP, passive non-trusted probe.
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/tw_stack_root.sh
source "${_script_dir}/../lib/tw_stack_root.sh"
TW_STACK_ROOT="$(tw_stack_root_from_script_dir "$_script_dir")" || {
  echo "[tinywebstack] ERROR: Cannot locate tinywebStack root from ${_script_dir}" >&2
  exit 1
}
if [[ -f "${TW_STACK_ROOT}/scripts/lib/common.sh" ]]; then
  # shellcheck source=scripts/lib/common.sh
  source "${TW_STACK_ROOT}/scripts/lib/common.sh"
  # shellcheck source=scripts/lib/domains.sh
  source "${TW_STACK_ROOT}/scripts/lib/domains.sh"
  # shellcheck source=scripts/lib/secrets.sh
  source "${TW_STACK_ROOT}/scripts/lib/secrets.sh"
  # shellcheck source=scripts/lib/mobilizon_python_path.sh
  source "${TW_STACK_ROOT}/scripts/lib/mobilizon_python_path.sh"
else
  # shellcheck source=scripts/lib/common.sh
  source "${TW_STACK_ROOT}/lib/common.sh"
  # shellcheck source=scripts/lib/domains.sh
  source "${TW_STACK_ROOT}/lib/domains.sh"
  # shellcheck source=scripts/lib/secrets.sh
  source "${TW_STACK_ROOT}/lib/secrets.sh"
  # shellcheck source=scripts/lib/mobilizon_python_path.sh
  source "${TW_STACK_ROOT}/lib/mobilizon_python_path.sh"
fi
load_config
load_secrets
export_mobilizon_pythonpath

usage() {
  cat <<'EOF'
Usage: verify-events-e2e.sh NODE_A NODE_B DOMAIN_A DOMAIN_B [REJECT_INSTANCE_HOST] [PARENT_USER]

Participant username defaults to $TWS_PARENT_USER (parent); its password resolves
via $<USERNAME>_PASSWORD env, then spark secrets (<USERNAME>_PASSWORD_<NODE>).
Without a lab CA (or TWS_CA_BUNDLE), TLS verification uses the system trust store;
set TWS_REQUIRE_LAB_CA=1 to keep the old hard-fail.

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
PARENT_USER=${6:-${TWS_PARENT_USER:-parent}}

require_cmd python3

ADMIN_A_PW="${MOBILIZON_ADMIN_PASSWORD:-${YUNOHOST_ADMIN_PASSWORD:-$(read_node_secret "$NODE_A" yunohost_admin_password || true)}}"
ADMIN_B_PW="${MOBILIZON_ADMIN_PASSWORD:-${YUNOHOST_ADMIN_PASSWORD:-$(read_node_secret "$NODE_B" yunohost_admin_password || true)}}"
validate_test_user_name "$PARENT_USER" parent-user
PARENT_A_PW="$(user_test_password "$NODE_A" "$PARENT_USER" PARENT_PASSWORD)"
PARENT_B_PW="$(user_test_password "$NODE_B" "$PARENT_USER" PARENT_PASSWORD)"
[[ -n "$ADMIN_A_PW" && -n "$ADMIN_B_PW" && -n "$PARENT_A_PW" && -n "$PARENT_B_PW" ]] || \
  die "yunohost_admin and ${PARENT_USER} passwords required (env ${PARENT_USER^^}_PASSWORD or $(secrets_file))"

# Lab CA is optional off-spark: fall back to the system trust store when absent.
CA_PEM="$(resolve_ca_bundle || true)"
require_ca_bundle_or_die "$CA_PEM"
if [[ -n "$CA_PEM" ]]; then
  export TWS_CA_BUNDLE="$CA_PEM"
else
  unset TWS_CA_BUNDLE
  log "No lab CA found — verifying TLS against the system trust store"
fi

MOB_ADMIN="${MOBILIZON_ADMIN_USER:-${YUNOHOST_ADMIN_USER:-twsowner}}"
export DOMAIN_A DOMAIN_B NODE_A NODE_B PARENT_A_PW PARENT_B_PW ADMIN_A_PW ADMIN_B_PW REJECT_HOST MOB_ADMIN PARENT_USER

python3 - <<'PY'
import json
import os
import ssl
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

from tinywebstack_family.mobilizon import (
    MobilizonClient,
    events_domain,
    sync_instance_federation,
    verify_passive_untrusted_probe,
    wait_for_federated_event,
)

def ssl_ctx():
    ca = os.environ.get("TWS_CA_BUNDLE")
    if ca and os.path.isfile(ca):
        return ssl.create_default_context(cafile=ca)
    # No lab CA: system trust store (public/CA-signed deployments, or a CA
    # installed into the OS trust store). Never disable verification.
    return ssl.create_default_context()

ctx = ssl_ctx()
domain_a = os.environ["DOMAIN_A"]
domain_b = os.environ["DOMAIN_B"]
host_a = events_domain(domain_a)
host_b = events_domain(domain_b)
base_a = f"https://{host_a}"
base_b = f"https://{host_b}"
admin = os.environ["MOB_ADMIN"]
admin_a = f"{admin}@{domain_a}"
admin_b = f"{admin}@{domain_b}"
parent_user = os.environ.get("PARENT_USER", "parent")
email_a = f"{parent_user}@{domain_a}"
email_b = f"{parent_user}@{domain_b}"
reject = os.environ["REJECT_HOST"]

NODEINFO_PATHS = (
    "/.well-known/nodeinfo/2.0",
    "/.well-known/nodeinfo/2.1",
)


def check_federation_public(url: str) -> None:
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=20, context=ctx) as resp:
            code = resp.getcode()
            body = resp.read(4000).decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        code = exc.code
        body = exc.read(4000).decode("utf-8", errors="replace")
    if code in (301, 302, 303, 307, 308):
        raise SystemExit(f"Federation URL redirected to SSO (expected public): {url} HTTP {code}")
    if code >= 400:
        raise SystemExit(f"Federation URL failed: {url} HTTP {code} body={body[:200]!r}")


print("== Federation discovery (no portal SSO) ==")
for base in (base_a, base_b):
    for path in NODEINFO_PATHS:
        check_federation_public(base + path)
print("  OK nodeinfo reachable without redirect")

print("== Federation sync (trusted pair, admin API) ==")
admin_a_client = MobilizonClient.login(base_a, admin_a, os.environ["ADMIN_A_PW"], ssl_context=ctx)
admin_b_client = MobilizonClient.login(base_b, admin_b, os.environ["ADMIN_B_PW"], ssl_context=ctx)
sync_a = sync_instance_federation(
    admin_a_client, local_main_domain=domain_a, trusted_main_domains=[domain_b], ssl_context=ctx
)
sync_b = sync_instance_federation(
    admin_b_client, local_main_domain=domain_b, trusted_main_domains=[domain_a], ssl_context=ctx
)
sync_a.raise_on_errors()
sync_b.raise_on_errors()
print(json.dumps({"A": sync_a.__dict__, "B": sync_b.__dict__}, indent=2, default=list))

print("== Cross-home event + RSVP (parent LDAP) ==")
client_a = MobilizonClient.login(base_a, email_a, os.environ["PARENT_A_PW"], ssl_context=ctx)
client_b = MobilizonClient.login(base_b, email_b, os.environ["PARENT_B_PW"], ssl_context=ctx)
actor_a = client_a.ensure_default_actor(email_a, ssl_context=ctx)
actor_b = client_b.ensure_default_actor(email_b, ssl_context=ctx)
start = datetime.now(timezone.utc) + timedelta(days=2)
end = start + timedelta(hours=2)
title = f"tinywebStack lab {int(start.timestamp())}"
created = client_a.create_public_event(
    title=title,
    begins_on=start,
    ends_on=end,
    organizer_actor_id=actor_a,
    ssl_context=ctx,
)
event_uuid = created.get("uuid")
if not event_uuid:
    raise SystemExit(f"createEvent missing uuid: {created}")
remote = wait_for_federated_event(client_b, str(event_uuid), ssl_context=ctx)
remote_id = remote.get("id")
if not remote_id:
    raise SystemExit(f"Federated event not on B: {remote}")
client_b.join_event(str(remote_id), actor_b, ssl_context=ctx)
print(f"  OK event uuid={event_uuid} joined on {host_b}")

print("== Passive non-trusted instance probe ==")
probe = verify_passive_untrusted_probe(admin_a_client, reject, ssl_context=ctx)
if probe.get("must_not_follow"):
    raise SystemExit(
        f"Instance must not follow {reject}; status={probe.get('followed_status')!r} "
        "(run federation sync without outbound probes)"
    )
print(f"  OK not following {reject} (status={probe.get('followed_status')})")
print("All Mobilizon event checks passed.")
PY

log "verify-events-e2e completed"
