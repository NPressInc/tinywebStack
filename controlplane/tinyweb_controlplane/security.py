"""Hashing and comparison for setup codes and bearer tokens."""

from __future__ import annotations

import hashlib
import hmac


def hash_secret(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def secrets_equal(got: str, expected: str) -> bool:
    if not got or not expected:
        return False
    return hmac.compare_digest(got.encode("utf-8"), expected.encode("utf-8"))
