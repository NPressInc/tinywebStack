"""Module tests against real Synapse 1.x types (matrix-synapse in test extra)."""

import pytest

pytest.importorskip("synapse")

from immutabledict import immutabledict

from synapse.api.errors import Codes, SynapseError, cs_error
from synapse.module_api import NOT_SPAM

from tinywebstack_family.module import FamilySpamCheckerModule
from tinywebstack_family.policy import empty_policy, write_policy_atomic


class MockMemberEvent:
    def __init__(self, mxid: str, membership: str = "join", *, immut: bool = False):
        self.type = "m.room.member"
        self.state_key = mxid
        body = {"membership": membership}
        self.content = immutabledict(body) if immut else body


class MockApi:
    def __init__(self, members=None):
        self.members = members or {}

    def register_spam_checker_callbacks(self, **kwargs):
        self.registered = kwargs

    def register_third_party_rules_callbacks(self, **kwargs):
        self.registered = kwargs

    async def get_room_state(self, room_id):
        return self.members


@pytest.fixture
def kid_policy_module(tmp_path):
    path = tmp_path / "family-policy.json"
    write_policy_atomic(
        path,
        {
            **empty_policy("family-a.test"),
            "parent_mxids": ["@parent:family-a.test"],
            "kids": {
                "@kid:family-a.test": {
                    "allowlist_mxids": ["@friend:family-b.test"],
                    "quiet_hours": {"start": "03:00", "end": "04:00", "timezone": "UTC"},
                }
            },
        },
    )
    api = MockApi()
    mod = FamilySpamCheckerModule({"policy_path": str(path), "reject_encryption": True}, api)
    return mod, api


def test_deny_tuple_serializes_without_cs_error_conflict():
    err = SynapseError(
        403,
        "Invites have been disabled on this server",
        errcode=Codes.FORBIDDEN,
        additional_fields={"tws_reason": "Contact not on kid allowlist"},
    )
    body = cs_error(err.msg, err.errcode, **err._additional_fields)
    assert body["errcode"] == Codes.FORBIDDEN
    assert body["tws_reason"] == "Contact not on kid allowlist"


@pytest.mark.asyncio
async def test_immutabledict_member_state(kid_policy_module):
    mod, api = kid_policy_module
    api.members = {
        ("m.room.member", "@kid:family-a.test"): MockMemberEvent(
            "@kid:family-a.test", immut=True
        ),
    }
    cb = mod.user_may_invite
    result = await cb("@parent:family-a.test", "@bob:evil.test", "!r:x")
    assert result is not NOT_SPAM
    assert result[0] == Codes.FORBIDDEN
    assert "tws_reason" in result[1]
    assert "msg" not in result[1]


@pytest.mark.asyncio
async def test_kid_private_chat_preset_without_is_direct_denied(kid_policy_module):
    mod, _ = kid_policy_module
    cb = mod.user_may_create_room
    result = await cb(
        "@kid:family-a.test",
        {"preset": "trusted_private_chat", "invite": ["@friend:family-b.test"]},
    )
    assert result is not NOT_SPAM


@pytest.mark.asyncio
async def test_kid_is_direct_one_invitee_allowed(kid_policy_module):
    mod, _ = kid_policy_module
    cb = mod.user_may_create_room
    result = await cb(
        "@kid:family-a.test",
        {
            "is_direct": True,
            "invite": ["@friend:family-b.test"],
            "preset": "trusted_private_chat",
        },
    )
    assert result is NOT_SPAM


@pytest.mark.asyncio
async def test_kid_is_direct_too_many_invites_denied(kid_policy_module):
    mod, _ = kid_policy_module
    cb = mod.user_may_create_room
    result = await cb(
        "@kid:family-a.test",
        {
            "is_direct": True,
            "invite": ["@a:x", "@b:y"],
        },
    )
    assert result is not NOT_SPAM
