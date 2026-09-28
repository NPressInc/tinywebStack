"""Unit tests for family policy (no Synapse)."""

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from tinywebstack_family.policy import (
    FamilyPolicy,
    PolicyStore,
    QuietHours,
    empty_policy,
    write_policy_atomic,
)


def test_allowlist_both_directions():
    policy = FamilyPolicy.from_dict(
        {
            "server_name": "family-a.test",
            "kids": {
                "@kid:family-a.test": {
                    "allowlist_mxids": ["@friend:family-b.test"],
                }
            },
            "parent_mxids": ["@parent:family-a.test"],
        }
    )
    assert policy.contact_allowed_between("@kid:family-a.test", "@friend:family-b.test")
    assert policy.contact_allowed_between("@friend:family-b.test", "@kid:family-a.test")
    assert not policy.contact_allowed_between("@kid:family-a.test", "@stranger:evil.test")
    assert policy.contact_allowed_between("@parent:family-a.test", "@anyone:else.test")


def test_parent_local_always_allowed_for_kid():
    policy = FamilyPolicy.from_dict(
        {
            "server_name": "family-a.test",
            "kids": {"@kid:family-a.test": {}},
            "parent_mxids": ["@parent:family-a.test"],
        }
    )
    assert policy.is_allowlisted_contact("@parent:family-a.test", policy.kids["@kid:family-a.test"])


def test_quiet_hours_simple_window():
    qh = QuietHours(start="22:00", end="23:00", timezone="UTC")
    assert qh.is_active(datetime(2026, 1, 1, 22, 30, tzinfo=ZoneInfo("UTC")))
    assert not qh.is_active(datetime(2026, 1, 1, 21, 30, tzinfo=ZoneInfo("UTC")))


def test_quiet_hours_midnight_wrap():
    qh = QuietHours(start="21:00", end="07:00", timezone="UTC")
    assert qh.is_active(datetime(2026, 1, 1, 23, 0, tzinfo=ZoneInfo("UTC")))
    assert qh.is_active(datetime(2026, 1, 2, 6, 30, tzinfo=ZoneInfo("UTC")))
    assert not qh.is_active(datetime(2026, 1, 2, 12, 0, tzinfo=ZoneInfo("UTC")))


def test_quiet_hours_timezone():
    policy = FamilyPolicy.from_dict(
        {
            "server_name": "family-a.test",
            "kids": {
                "@kid:family-a.test": {
                    "quiet_hours": {
                        "start": "21:00",
                        "end": "07:00",
                        "timezone": "America/Los_Angeles",
                        "days": [0, 1, 2, 3, 4, 5, 6],
                    }
                }
            },
        }
    )
    # 2026-01-15 05:00 UTC = 2026-01-14 21:00 PST (still quiet)
    when = datetime(2026, 1, 15, 5, 0, tzinfo=ZoneInfo("UTC"))
    assert policy.kid_in_quiet_hours("@kid:family-a.test", when)


def test_fail_closed_invalid_json(tmp_path):
    path = tmp_path / "family-policy.json"
    path.write_text("{not json", encoding="utf-8")
    store = PolicyStore(path)
    p = store.policy
    assert p.fail_closed_kids
    assert not p.contact_allowed_between("@kid:a", "@friend:b")


def test_policy_store_reload(tmp_path):
    path = tmp_path / "family-policy.json"
    write_policy_atomic(path, empty_policy("family-a.test"))
    store = PolicyStore(path)
    assert store.policy.server_name == "family-a.test"
    write_policy_atomic(
        path,
        {
            **empty_policy("family-a.test"),
            "kids": {"@kid:family-a.test": {"allowlist_mxids": []}},
        },
    )
    store.reload_if_changed()
    assert "@kid:family-a.test" in store.policy.kids
