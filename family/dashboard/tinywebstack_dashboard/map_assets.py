"""Signed query tokens for map static assets (glyphs/sprites) without Bearer on every fetch."""

from __future__ import annotations

import os
from typing import Optional

from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

_MAP_TOKEN_SALT = "tws-map-assets-v1"
_DEFAULT_MAX_AGE_S = 86_400


def _serializer() -> URLSafeTimedSerializer:
    secret = os.environ.get("TWS_CSRF_SECRET") or os.environ.get("TWS_INVITE_SECRET") or "dev-insecure"
    return URLSafeTimedSerializer(secret, salt=_MAP_TOKEN_SALT)


def mint_map_assets_token(username: str, max_age_s: int = _DEFAULT_MAX_AGE_S) -> tuple[str, str]:
    """Return (query_string, token) e.g. ('t=...', raw token)."""
    del max_age_s  # enforced in loads()
    token = _serializer().dumps({"u": username.strip().lower()})
    return f"t={token}", token


def username_from_map_assets_token(token: str) -> Optional[str]:
    if not token:
        return None
    try:
        payload = _serializer().loads(token, max_age=_DEFAULT_MAX_AGE_S)
    except (BadSignature, SignatureExpired):
        return None
    if not isinstance(payload, dict):
        return None
    user = str(payload.get("u", "")).strip().lower()
    return user or None


def token_from_query(query_params: dict) -> Optional[str]:
    raw = query_params.get("t")
    if isinstance(raw, str) and raw.strip():
        return raw.strip()
    if isinstance(raw, list) and raw:
        return str(raw[0]).strip()
    return None
