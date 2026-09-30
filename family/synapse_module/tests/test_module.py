"""Synapse module callback tests with mocked ModuleApi."""

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from tinywebstack_family.module import NOT_SPAM, FamilySpamCheckerModule
from tinywebstack_family.policy import write_policy_atomic, empty_policy


class MockMemberEvent:
    def __init__(self, mxid: str, membership: str = "join"):
        self.type = "m.room.member"
        self.state_key = mxid
        self.content = {"membership": membership}


class MockApi:
    def __init__(self, members=None):
        self.members = members or {}
        self.registered = {}

    def register_spam_checker_callbacks(self, **kwargs):
        self.registered.update(kwargs)

    def register_third_party_rules_callbacks(self, **kwargs):
        self.registered.update(kwargs)

    async def get_room_state(self, room_id):
        return self.members


def _denied(result) -> bool:
    return result is not NOT_SPAM


@pytest.fixture
def policy_file(tmp_path):
    path = tmp_path / "family-policy.json"
    write_policy_atomic(
        path,
        {
            **empty_policy("family-a.test"),
            "parent_mxids": ["@parent:family-a.test"],
            "kids": {
                "@kid:family-a.test": {
                    "allowlist_mxids": ["@friend:family-b.test"],
                    "quiet_hours": {
                        "start": "03:00",
                        "end": "04:00",
                        "timezone": "UTC",
                    },
                }
            },
        },
    )
    return path


@pytest.fixture
def module(policy_file):
    api = MockApi(members={})
    mod = FamilySpamCheckerModule(
        {"policy_path": str(policy_file), "reject_encryption": True},
        api,
    )
    mod._callbacks = api.registered
    return mod, api


@pytest.mark.asyncio
async def test_invite_allow(module):
    mod, _ = module
    # Pin outside quiet hours (window is 03:00-04:00 UTC; wall-clock would make
    # this flaky once a day). The allowlist behaviour under test is unaffected.
    mod.store.policy.kid_in_quiet_hours = lambda kid_mxid, when=None: False  # type: ignore[method-assign]
    result = await mod._callbacks["user_may_invite"](
        "@kid:family-a.test", "@friend:family-b.test", "!r:family-a.test"
    )
    assert result is NOT_SPAM


@pytest.mark.asyncio
async def test_invite_deny_stranger(module):
    mod, _ = module
    result = await mod._callbacks["user_may_invite"](
        "@kid:family-a.test", "@stranger:evil.test", "!r:family-a.test"
    )
    assert _denied(result)


@pytest.mark.asyncio
async def test_adult_invite_blocked_in_kid_room(module):
    mod, api = module
    api.members = {
        ("m.room.member", "@kid:family-a.test"): MockMemberEvent("@kid:family-a.test"),
    }
    result = await mod._callbacks["user_may_invite"](
        "@parent:family-a.test", "@bob:family-a.test", "!r:family-a.test"
    )
    assert _denied(result)


@pytest.mark.asyncio
async def test_room_state_map_values(module):
    mod, api = module
    api.members = {
        ("m.room.member", "@kid:family-a.test"): MockMemberEvent("@kid:family-a.test"),
        ("m.room.member", "@friend:family-b.test"): MockMemberEvent("@friend:family-b.test"),
    }
    members = await mod._room_member_mxids("!room")
    assert "@kid:family-a.test" in members
    assert "@friend:family-b.test" in members


@pytest.mark.asyncio
async def test_kid_cannot_create_group_room(module):
    mod, _ = module
    result = await mod._callbacks["user_may_create_room"](
        "@kid:family-a.test", {"preset": "public_chat", "is_direct": False}
    )
    assert _denied(result)


@pytest.mark.asyncio
async def test_3pid_denied_for_kid(module):
    mod, _ = module
    result = await mod._callbacks["user_may_send_3pid_invite"](
        "@kid:family-a.test", "email", "x@y.com", "!r:x"
    )
    assert _denied(result)


@pytest.mark.asyncio
async def test_quiet_hours_message(module):
    mod, _ = module

    def _always_quiet(kid_mxid: str, when=None):
        return kid_mxid == "@kid:family-a.test"

    mod.store.policy.kid_in_quiet_hours = _always_quiet  # type: ignore[method-assign]
    event = {"sender": "@kid:family-a.test", "room_id": "!r:x", "type": "m.room.message"}
    result = await mod._callbacks["check_event_for_spam"](event)
    assert _denied(result)


@pytest.mark.asyncio
async def test_encryption_rejected(module):
    mod, _ = module
    event = {"type": "m.room.encryption", "sender": "@parent:family-a.test"}
    allowed, info = await mod._callbacks["check_event_allowed"](event, [])
    assert allowed is False
    assert info and "encryption" in info.get("tws_reason", "").lower()
