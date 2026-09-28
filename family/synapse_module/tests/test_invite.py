import time

import pytest

from tinywebstack_family.invite import create_invite_token, verify_invite_token


def test_invite_roundtrip():
    token, nonce = create_invite_token("family-a.test", "secret", ttl_seconds=600)
    assert nonce
    payload = verify_invite_token(token, "secret")
    assert payload["domain"] == "family-a.test"
    assert payload["nonce"] == nonce


def test_invite_wrong_secret():
    token, _ = create_invite_token("family-a.test", "secret")
    with pytest.raises(ValueError, match="signature"):
        verify_invite_token(token, "other")


def test_invite_expired():
    token, _ = create_invite_token("family-a.test", "secret", ttl_seconds=-10)
    with pytest.raises(ValueError, match="expired"):
        verify_invite_token(token, "secret")
