"""Unit tests for login_ticket and Synapse auth callback wiring."""

import time

import pytest

from tinywebstack_family.login_ticket import make_ticket, verify_ticket
from tinywebstack_family.module import FamilySpamCheckerModule


def test_ticket_roundtrip():
    secret = b"\x01" * 32
    now = 1_700_000_000
    ticket = make_ticket(secret, "kid1", now, ttl=60)
    assert verify_ticket(secret, ticket, now + 30) == "kid1"
    assert verify_ticket(secret, ticket, now + 59) == "kid1"


def test_ticket_expired():
    secret = b"\x02" * 32
    now = 1_700_000_000
    ticket = make_ticket(secret, "alice", now, ttl=60)
    assert verify_ticket(secret, ticket, now + 61) is None


def test_ticket_tamper():
    secret = b"\x03" * 32
    now = 1_700_000_000
    ticket = make_ticket(secret, "bob", now, ttl=60)
    bad = ticket[:-1] + ("0" if ticket[-1] != "0" else "1")
    assert verify_ticket(secret, bad, now) is None


def test_make_ticket_rejects_ttl_over_300():
    secret = b"\x04" * 32
    with pytest.raises(ValueError):
        make_ticket(secret, "kid", 0, ttl=301)


def test_verify_rejects_future_exp_beyond_max_ttl():
    import hmac
    from hashlib import sha256

    secret = b"\x05" * 32
    now = 1_700_000_000
    exp = now + 400
    nonce = "a" * 16
    payload = f"v1.kid.{exp}.{nonce}"
    sig = hmac.new(secret, payload.encode("utf-8"), sha256).hexdigest()
    ticket = f"{payload}.{sig}"
    assert verify_ticket(secret, ticket, now) is None


@pytest.mark.asyncio
async def test_login_ticket_callback_wrong_user(tmp_path):
    from tinywebstack_family.policy import empty_policy, write_policy_atomic

    policy = tmp_path / "policy.json"
    write_policy_atomic(policy, empty_policy("x.test"))

    class Api:
        def register_spam_checker_callbacks(self, **kwargs):
            pass

        def register_password_auth_provider_callbacks(self, **kwargs):
            self.auth = kwargs

        def get_qualified_user_id(self, localpart):
            return f"@{localpart}:x.test"

    api = Api()
    secret = b"\x06" * 32
    mod = FamilySpamCheckerModule(
        {"policy_path": str(policy), "login_ticket_secret": secret.hex()},
        api,
    )
    ticket = make_ticket(secret, "kid1", int(time.time()))
    cb = api.auth["auth_checkers"][("org.tinywebstack.login_ticket", ("ticket",))]
    ok = await cb("kid1", "org.tinywebstack.login_ticket", {"ticket": ticket})
    assert ok == ("@kid1:x.test", None)
    bad = await cb("other", "org.tinywebstack.login_ticket", {"ticket": ticket})
    assert bad is None


def test_password_auth_not_registered_without_secret(tmp_path):
    from tinywebstack_family.policy import empty_policy, write_policy_atomic

    policy = tmp_path / "policy.json"
    write_policy_atomic(policy, empty_policy("x.test"))

    class Api:
        def register_spam_checker_callbacks(self, **kwargs):
            pass

        def register_password_auth_provider_callbacks(self, **kwargs):
            self.auth = kwargs

    api = Api()
    FamilySpamCheckerModule({"policy_path": str(policy)}, api)
    assert not hasattr(api, "auth")
