"""Mobilizon (events) helpers: hostnames, federation sync via GraphQL admin API."""

from __future__ import annotations

import json
import ssl
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple


def events_domain(main_domain: str) -> str:
    """Mobilizon YunoHost app subdomain for a family main domain."""
    main = main_domain.strip().lower()
    if main.startswith("mobilizon."):
        return main
    return f"mobilizon.{main}"


def peer_events_hosts(trusted_main_domains: Iterable[str]) -> List[str]:
    return sorted({events_domain(d) for d in trusted_main_domains if d and str(d).strip()})


def relay_address_from_follower(follower: Dict[str, Any]) -> Optional[str]:
    """Best-effort hostname for acceptRelay/rejectRelay from a relayFollowers element."""
    actor = follower.get("actor") or {}
    for key in ("preferredUsername", "domain", "url"):
        val = actor.get(key)
        if isinstance(val, str) and val.strip():
            text = val.strip()
            if key == "url" and "://" in text:
                text = text.split("://", 1)[1].split("/", 1)[0]
            return text.lower()
    target = follower.get("targetActor") or {}
    val = target.get("preferredUsername") or target.get("domain")
    if isinstance(val, str) and val.strip():
        return val.strip().lower()
    return None


@dataclass
class MobilizonClient:
    api_url: str
    access_token: str

    @classmethod
    def login(
        cls,
        base_url: str,
        email: str,
        password: str,
        *,
        ssl_context: Optional[ssl.SSLContext] = None,
        timeout: int = 30,
    ) -> "MobilizonClient":
        base = base_url.rstrip("/")
        api_url = f"{base}/api"
        body = {
            "query": (
                "mutation Login($email: String!, $password: String!) {"
                " login(email: $email, password: $password) { accessToken }"
                "}"
            ),
            "variables": {"email": email, "password": password},
        }
        data = _post_json(api_url, body, headers={}, ssl_context=ssl_context, timeout=timeout)
        token = ((data.get("data") or {}).get("login") or {}).get("accessToken")
        if not token:
            errors = data.get("errors") or data
            raise RuntimeError(f"Mobilizon login failed: {errors}")
        return cls(api_url=api_url, access_token=token)

    def gql(
        self,
        query: str,
        variables: Optional[Dict[str, Any]] = None,
        *,
        ssl_context: Optional[ssl.SSLContext] = None,
        timeout: int = 30,
    ) -> Dict[str, Any]:
        headers = {"Authorization": f"Bearer {self.access_token}"}
        body: Dict[str, Any] = {"query": query}
        if variables is not None:
            body["variables"] = variables
        data = _post_json(self.api_url, body, headers=headers, ssl_context=ssl_context, timeout=timeout)
        if data.get("errors"):
            raise RuntimeError(json.dumps(data["errors"], ensure_ascii=False))
        return data.get("data") or {}

    def add_instance(self, domain: str, **kwargs: Any) -> None:
        self.gql(
            'mutation AddInstance($domain: String!) { addInstance(domain: $domain) { domain } }',
            {"domain": domain},
            **kwargs,
        )

    def accept_relay(self, address: str, **kwargs: Any) -> None:
        self.gql(
            'mutation AcceptRelay($address: String!) { acceptRelay(address: $address) { id } }',
            {"address": address},
            **kwargs,
        )

    def reject_relay(self, address: str, **kwargs: Any) -> None:
        self.gql(
            'mutation RejectRelay($address: String!) { rejectRelay(address: $address) { id } }',
            {"address": address},
            **kwargs,
        )

    def list_relay_followers(self, *, limit: int = 50, **kwargs: Any) -> List[Dict[str, Any]]:
        data = self.gql(
            "query RelayFollowers($limit: Int) { relayFollowers(limit: $limit) { elements { id actor { preferredUsername url domain } targetActor { preferredUsername domain } approved } } }",
            {"limit": limit},
            **kwargs,
        )
        return list((data.get("relayFollowers") or {}).get("elements") or [])

    def instance_followed_status(self, domain: str, **kwargs: Any) -> str:
        data = self.gql(
            "query InstanceStatus($domain: ID!) { instance(domain: $domain) { domain followedStatus followerStatus } }",
            {"domain": domain},
            **kwargs,
        )
        inst = data.get("instance") or {}
        return str(inst.get("followedStatus") or "NONE")

    def ensure_default_actor(self, username: str, **kwargs: Any) -> str:
        ident = self.gql(
            "query { loggedUser { id defaultActor { id preferredUsername } } }",
            **kwargs,
        )
        actor = ((ident.get("loggedUser") or {}).get("defaultActor") or {})
        if actor.get("id"):
            return str(actor["id"])
        slug = username.split("@")[0].replace(".", "-").lower()[:30] or "family"
        created = self.gql(
            "mutation CreatePerson($u: String!, $n: String!) { createPerson(preferredUsername: $u, name: $n) { id preferredUsername } }",
            {"u": slug, "n": username.split("@")[0].title()},
            **kwargs,
        )
        person = created.get("createPerson") or {}
        if not person.get("id"):
            raise RuntimeError(f"createPerson failed: {created}")
        return str(person["id"])

    def create_public_event(
        self,
        *,
        title: str,
        begins_on: datetime,
        ends_on: datetime,
        organizer_actor_id: str,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        data = self.gql(
            """
            mutation CreateEvent($title: String!, $begins: DateTime!, $ends: DateTime!, $org: ID!) {
              createEvent(
                title: $title
                description: "tinywebStack lab event"
                beginsOn: $begins
                endsOn: $ends
                status: CONFIRMED
                visibility: PUBLIC
                organizerActorId: $org
              ) { id uuid url }
            }
            """,
            {
                "title": title,
                "begins": begins_on.isoformat(),
                "ends": ends_on.isoformat(),
                "org": organizer_actor_id,
            },
            **kwargs,
        )
        ev = data.get("createEvent")
        if not ev or not ev.get("id"):
            raise RuntimeError(f"createEvent failed: {data}")
        return ev

    def event_by_uuid(self, event_uuid: str, **kwargs: Any) -> Optional[Dict[str, Any]]:
        data = self.gql(
            "query EventByUuid($uuid: UUID!) { event(uuid: $uuid) { id uuid url } }",
            {"uuid": event_uuid},
            **kwargs,
        )
        ev = data.get("event")
        return ev if isinstance(ev, dict) else None

    def join_event(self, event_id: str, actor_id: str, **kwargs: Any) -> str:
        data = self.gql(
            "mutation Join($eventId: ID!, $actorId: ID!) { joinEvent(eventId: $eventId, actorId: $actorId) { id } }",
            {"eventId": event_id, "actorId": actor_id},
            **kwargs,
        )
        part = data.get("joinEvent") or {}
        if not part.get("id"):
            raise RuntimeError(f"joinEvent failed: {data}")
        return str(part["id"])


def normalize_hostname(host: str) -> str:
    text = host.strip().lower()
    if "://" in text:
        text = text.split("://", 1)[1]
    return text.split("/", 1)[0].split(":", 1)[0]


def is_trusted_relay(host: str, trusted_hosts: Set[str], local_events_host: str) -> bool:
    host = normalize_hostname(host)
    if host == local_events_host:
        return True
    if host in trusted_hosts:
        return True
    for trusted in trusted_hosts:
        if host == trusted or host.endswith("." + trusted):
            return True
    return False


@dataclass
class FederationSyncResult:
    local_events_host: str
    outgoing_ok: List[str] = field(default_factory=list)
    outgoing_errors: Dict[str, str] = field(default_factory=dict)
    accepted_relays: List[str] = field(default_factory=list)
    rejected_relays: List[str] = field(default_factory=list)

    def raise_on_errors(self) -> None:
        if self.outgoing_errors:
            raise RuntimeError(
                f"Mobilizon federation sync errors: {json.dumps(self.outgoing_errors, ensure_ascii=False)}"
            )


def sync_instance_federation(
    client: MobilizonClient,
    *,
    local_main_domain: str,
    trusted_main_domains: Iterable[str],
    ssl_context: Optional[ssl.SSLContext] = None,
    timeout: int = 30,
) -> FederationSyncResult:
    """
    Align Mobilizon ActivityPub relays with tinywebStack trusted_domains (pairwise allowlist).

    - Outgoing: addInstance for each peer events host (errors surfaced).
    - Incoming: acceptRelay for trusted pending followers, rejectRelay for others.

    Never probes or follows non-trusted instances (see verify_passive_untrusted_probe).
    """
    local_events = events_domain(local_main_domain)
    trusted_hosts = set(peer_events_hosts(trusted_main_domains))
    trusted_hosts.add(local_events)

    result = FederationSyncResult(local_events_host=local_events)
    for peer in peer_events_hosts(trusted_main_domains):
        if peer == local_events:
            continue
        try:
            client.add_instance(peer, ssl_context=ssl_context, timeout=timeout)
            result.outgoing_ok.append(peer)
        except RuntimeError as exc:
            result.outgoing_errors[peer] = str(exc)

    for follower in client.list_relay_followers(ssl_context=ssl_context, timeout=timeout):
        if follower.get("approved"):
            continue
        address = relay_address_from_follower(follower)
        if not address:
            continue
        if is_trusted_relay(address, trusted_hosts, local_events):
            client.accept_relay(address, ssl_context=ssl_context, timeout=timeout)
            result.accepted_relays.append(address)
        else:
            client.reject_relay(address, ssl_context=ssl_context, timeout=timeout)
            result.rejected_relays.append(address)

    return result


def verify_passive_untrusted_probe(
    client: MobilizonClient,
    probe_host: str,
    *,
    ssl_context: Optional[ssl.SSLContext] = None,
    timeout: int = 30,
) -> Dict[str, Any]:
    """
    Passive check: we must not be actively following a non-trusted public instance.
    Does not call addInstance or otherwise initiate outbound follows.
    """
    probe = normalize_hostname(probe_host)
    status = client.instance_followed_status(probe, ssl_context=ssl_context, timeout=timeout)
    bad = status in ("APPROVED", "PENDING")
    return {"probe_host": probe, "followed_status": status, "must_not_follow": bad}


def wait_for_federated_event(
    client: MobilizonClient,
    event_uuid: str,
    *,
    ssl_context: Optional[ssl.SSLContext] = None,
    timeout_sec: int = 120,
    poll_interval: float = 3.0,
) -> Dict[str, Any]:
    deadline = time.time() + timeout_sec
    last = None
    while time.time() < deadline:
        last = client.event_by_uuid(event_uuid, ssl_context=ssl_context)
        if last and last.get("id"):
            return last
        time.sleep(poll_interval)
    raise RuntimeError(f"Federated event {event_uuid} not visible within {timeout_sec}s (last={last})")


def kid_events_enabled(kid_entry: Dict[str, Any]) -> bool:
    """Default True when unset (parents opt out explicitly)."""
    if not isinstance(kid_entry, dict):
        return True
    if "events_enabled" not in kid_entry:
        return True
    return bool(kid_entry.get("events_enabled"))


def kid_usernames_with_events(policy: Dict[str, Any]) -> Set[str]:
    kids = policy.get("kids") or {}
    out: Set[str] = set()
    for mxid, entry in kids.items():
        if not isinstance(entry, dict):
            continue
        if not kid_events_enabled(entry):
            continue
        if not str(mxid).startswith("@") or ":" not in str(mxid):
            continue
        local = str(mxid)[1:].split(":", 1)[0]
        out.add(local)
    return out


def _post_json(
    url: str,
    body: Dict[str, Any],
    *,
    headers: Dict[str, str],
    ssl_context: Optional[ssl.SSLContext] = None,
    timeout: int = 30,
) -> Dict[str, Any]:
    payload = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json", **headers},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl_context) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} from Mobilizon API: {raw[:500]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Mobilizon API unreachable at {url}: {exc}") from exc
    return json.loads(raw)
