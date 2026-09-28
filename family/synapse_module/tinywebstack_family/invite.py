"""One-time household invite tokens (HMAC, short TTL)."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import time
from typing import Any, Dict, Optional, Tuple


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _b64url_decode(s: str) -> bytes:
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def sign_payload(payload: Dict[str, Any], secret: str) -> str:
    body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()


def create_invite_token(domain: str, secret: str, ttl_seconds: int = 3600) -> Tuple[str, str]:
    """Return (token, nonce) for storage in pending invites."""
    nonce = secrets.token_urlsafe(16)
    payload = {
        "v": 1,
        "domain": domain,
        "nonce": nonce,
        "exp": int(time.time()) + ttl_seconds,
    }
    sig = sign_payload(payload, secret)
    raw = json.dumps({"p": payload, "s": sig}, separators=(",", ":")).encode("utf-8")
    return _b64url(raw), nonce


def decode_invite_token(token: str) -> Dict[str, Any]:
    raw = json.loads(_b64url_decode(token))
    if not isinstance(raw, dict) or "p" not in raw or "s" not in raw:
        raise ValueError("Malformed invite token")
    return raw


def verify_invite_token(token: str, secret: str) -> Dict[str, Any]:
    raw = decode_invite_token(token)
    payload = raw["p"]
    expected = sign_payload(payload, secret)
    if not hmac.compare_digest(expected, raw["s"]):
        raise ValueError("Invalid invite signature")
    if int(payload.get("exp", 0)) < int(time.time()):
        raise ValueError("Invite expired")
    if not payload.get("domain") or not payload.get("nonce"):
        raise ValueError("Invite payload incomplete")
    return payload
