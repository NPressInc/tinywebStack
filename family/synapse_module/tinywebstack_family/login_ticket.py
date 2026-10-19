"""Short-lived HMAC tickets for server-side Matrix login (code enrollment)."""

from __future__ import annotations

import hmac
import secrets
from hashlib import sha256
from typing import Optional

_VERSION = "v1"
_MAX_TTL = 300


def make_ticket(secret: bytes, localpart: str, now: int, ttl: int = 60) -> str:
    if ttl > _MAX_TTL:
        raise ValueError(f"ttl must be <= {_MAX_TTL}")
    if not localpart or "." in localpart or ":" in localpart:
        raise ValueError("invalid localpart")
    exp = now + ttl
    nonce = secrets.token_hex(8)
    payload = f"{_VERSION}.{localpart}.{exp}.{nonce}"
    sig = hmac.new(secret, payload.encode("utf-8"), sha256).hexdigest()
    return f"{payload}.{sig}"


def verify_ticket(secret: bytes, ticket: str, now: int) -> Optional[str]:
    if not ticket or not secret:
        return None
    parts = ticket.split(".")
    if len(parts) != 5:
        return None
    ver, localpart, exp_s, nonce, sig = parts
    if ver != _VERSION:
        return None
    if len(nonce) != 16 or not all(c in "0123456789abcdef" for c in nonce.lower()):
        return None
    try:
        exp = int(exp_s)
    except ValueError:
        return None
    if exp < now:
        return None
    if exp - now > _MAX_TTL:
        return None
    payload = f"{_VERSION}.{localpart}.{exp_s}.{nonce}"
    expected = hmac.new(secret, payload.encode("utf-8"), sha256).hexdigest()
    if not hmac.compare_digest(expected, sig):
        return None
    return localpart
