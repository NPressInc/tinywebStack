"""Synapse module callback tests with mocked ModuleApi."""

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from tinywebstack_family.module import FamilySpamCheckerModule
from tinywebstack_family.policy import write_policy_atomic, empty_policy


class MockApi:
    NOT_SPAM = object()

    def __init__(self, members=None):
        self.members = members or []
        self.registered = {}

    def register_spam_checker_callbacks(self, **kwargs):
        self.registered.update(kwargs)

    def register_third_party_rules_callbacks(self, **kwargs):
        self.registered.update(kwargs)

    async def get_room_state(self, room_id):
        return self.members


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
    api = MockApi(members=[])
    mod = FamilySpamCheckerModule(
        {"policy_path": str(policy_file), "reject_encryption": True},
        api,
    )
    mod._callbacks = api.registered
    return mod, api


@pytest.mark.asyncio
async def test_invite_allow(module):
    mod, _ = module
    assert (
        await mod._callbacks["user_may_invite"](
            "@kid:family-a.test", "@friend:family-b.test", "!r:family-a.test"
        )
        is mod.api.NOT_SPAM
    )


@pytest.mark.asyncio
async def test_invite_deny_stranger(module):
    mod, _ = module
    result = await mod._callbacks["user_may_invite"](
        "@kid:family-a.test", "@stranger:evil.test", "!r:family-a.test"
    )
    assert result[0] == "M_FORBIDDEN"


@pytest.mark.asyncio
async def test_invite_reverse_direction(module):
    mod, _ = module
    result = await mod._callbacks["user_may_invite"](
        "@stranger:evil.test", "@kid:family-a.test", "!r:family-a.test"
    )
    assert result[0] == "M_FORBIDDEN"


@pytest.mark.asyncio
async def test_3pid_denied_for_kid(module):
    mod, _ = module
    result = await mod._callbacks["user_may_send_3pid_invite"](
        "@kid:family-a.test", "email", "x@y.com", "!r:x"
    )
    assert result[0] == "M_FORBIDDEN"


@pytest.mark.asyncio
async def test_quiet_hours_message(module):
    mod, api = module
    mod.store._policy  # load

    def _always_quiet(kid_mxid: str, when=None):
        return kid_mxid == "@kid:family-a.test"

    mod.store.policy.kid_in_quiet_hours = _always_quiet  # type: ignore[method-assign]
    event = {"sender": "@kid:family-a.test", "room_id": "!r:x", "type": "m.room.message"}
    result = await mod._callbacks["check_event_for_spam"](event)
    assert result[0] == "M_FORBIDDEN"


@pytest.mark.asyncio
async def test_parent_exempt_quiet_hours(module):
    mod, _ = module
    when = datetime(2026, 1, 1, 23, 0, tzinfo=ZoneInfo("UTC"))
    assert not mod.store.policy.kid_in_quiet_hours("@parent:family-a.test", when)
    event = {"sender": "@parent:family-a.test", "room_id": "!r:x"}
    assert await mod._callbacks["check_event_for_spam"](event) is mod.api.NOT_SPAM


@pytest.mark.asyncio
async def test_encryption_rejected(module):
    mod, _ = module
    event = {"type": "m.room.encryption", "sender": "@parent:family-a.test"}
    result = await mod._callbacks["check_event_allowed"](event, [])
    assert result[0] == "M_FORBIDDEN"


@pytest.mark.asyncio
async def test_publish_denied_for_kid(module):
    mod, _ = module
    result = await mod._callbacks["user_may_publish_room"]("@kid:family-a.test", "!r:x")
    assert result[0] == "M_FORBIDDEN"
