"""Incoming household link invites (redeemer side) + preview/decline helpers."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Literal, Optional, Tuple

from tinywebstack_family.invite import decode_invite_token

from tinywebstack_dashboard.peer_verify import _fetch_json, _ssl_context, verify_peer_domain

FederationSyncMode = Literal["async", "sync", "none"]


@dataclass(frozen=True)
class RedeemResult:
    linked_domain: str
    synapse_federation: str
    mobilizon_relay: str
    user_message: str
    already_linked: bool = False


class LinkInviteError(Exception):
    def __init__(self, status: int, detail: str) -> None:
        super().__init__(detail)
        self.status = status
        self.detail = detail


def post_json(url: str, body: Dict[str, Any], timeout: int = 20) -> Dict[str, Any]:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout, context=_ssl_context()) as resp:
        return json.loads(resp.read().decode("utf-8"))


def peer_family_api_base(inviter_domain: str) -> str:
    override = os.environ.get("TWS_PEER_INVITE_VERIFY_BASE", "").strip()
    if override:
        return override.rstrip("/")
    return f"https://{inviter_domain}/family"


def fetch_inviter_well_known(inviter_domain: str) -> Tuple[Optional[Dict[str, Any]], bool]:
    doc = _fetch_json(f"https://{inviter_domain}/.well-known/tinywebstack-family.json")
    return doc, doc is not None


def family_name_from_well_known(doc: Optional[Dict[str, Any]], domain: str) -> str:
    if not doc:
        return domain
    for key in ("family_name", "display_name", "server_name"):
        val = str(doc.get(key, "")).strip()
        if val:
            return val
    return domain


def decode_inviter_domain(token: str) -> str:
    try:
        decoded = decode_invite_token(token.strip())
        issuer = str(decoded["p"]["domain"]).strip()
    except Exception as exc:
        raise LinkInviteError(400, f"Invalid token: {exc}") from exc
    if not issuer:
        raise LinkInviteError(400, "Invalid token: missing inviter domain")
    return issuer


def preview_link_invite(
    token: str,
    *,
    own_domain: str,
    trusted_domains: List[str],
) -> Dict[str, Any]:
    token = token.strip()
    issuer = decode_inviter_domain(token)
    if issuer == own_domain:
        raise LinkInviteError(400, "cannot link to yourself")
    try:
        decoded = decode_invite_token(token)
        exp = int(decoded["p"].get("exp", 0))
    except Exception:
        exp = 0
    well_known, reachable = fetch_inviter_well_known(issuer)
    family_name = family_name_from_well_known(well_known, issuer)
    return {
        "inviter_domain": issuer,
        "inviter_family_name": family_name,
        "expires_at": exp,
        "already_linked": issuer in set(trusted_domains),
        "reachable": reachable,
    }


def decline_link_invite_remote(token: str, inviter_domain: str) -> None:
    base = peer_family_api_base(inviter_domain)
    url = f"{base.rstrip('/')}/api/invite/decline"
    try:
        post_json(url, {"token": token.strip()})
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, json.JSONDecodeError):
        pass


def redeem_link_invite(
    token: str,
    *,
    own_domain: str,
    trusted_domains: List[str],
    post_peer_json: Optional[Callable[[str, Dict[str, Any]], Dict[str, Any]]] = None,
    add_trusted_domain: Callable[[str], None],
    run_federation_sync: Callable[[], Tuple[str, str]],
    federation_sync_mode: FederationSyncMode = "sync",
) -> RedeemResult:
    token = token.strip()
    issuer = decode_inviter_domain(token)
    if issuer == own_domain:
        raise LinkInviteError(400, "cannot link to yourself")

    if issuer in set(trusted_domains):
        return RedeemResult(
            linked_domain=issuer,
            synapse_federation="ok",
            mobilizon_relay="skipped",
            user_message=f"Already linked with {issuer}.",
            already_linked=True,
        )

    peer_base = peer_family_api_base(issuer)
    verify_url = f"{peer_base.rstrip('/')}/api/invite/verify"
    peer_post = post_peer_json or post_json
    try:
        verify_resp = peer_post(
            verify_url,
            {"token": token, "redeemer_domain": own_domain},
        )
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        if exc.code == 403 and "already used" in body.lower():
            raise LinkInviteError(
                409,
                "This invite was already used. Ask the other household to create a new invite.",
            ) from exc
        raise LinkInviteError(
            exc.code,
            f"Peer rejected the invite (HTTP {exc.code}): {body[:200]}",
        ) from exc
    except (urllib.error.URLError, OSError) as exc:
        raise LinkInviteError(502, f"Could not reach peer at {verify_url}: {exc}") from exc

    if not verify_resp.get("matrix_server_key"):
        peer_host = verify_resp.get("matrix_server") or issuer
        verify_peer_domain(peer_host, None)

    add_trusted_domain(issuer)

    synapse_status = "skipped"
    mobilizon_status = "skipped"
    if federation_sync_mode in ("sync", "async"):
        synapse_status, mobilizon_status = run_federation_sync()

    return RedeemResult(
        linked_domain=issuer,
        synapse_federation=synapse_status,
        mobilizon_relay=mobilizon_status,
        user_message=f"Linked with {issuer}. Federation allowlist sync requested.",
    )


def linked_families_payload(
    trusted_domains: List[str],
    own_domain: str,
) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    for domain in sorted(set(trusted_domains)):
        if not domain or domain == own_domain:
            continue
        doc, _ = fetch_inviter_well_known(domain)
        out.append(
            {
                "domain": domain,
                "family_name": family_name_from_well_known(doc, domain),
            }
        )
    return out
