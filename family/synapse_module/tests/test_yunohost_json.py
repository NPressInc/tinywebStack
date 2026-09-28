"""YunoHost 12 JSON fixture tests (real CLI shapes)."""

import json

from tinywebstack_family.yunohost_json import (
    group_exists,
    groups_map,
    permission_exists,
    permissions_map,
    users_map,
)


def test_groups_wrapped():
    raw = json.loads(
        '{"groups": {"parents": {"name": "parents"}, "kids": {"name": "kids"}}}'
    )
    assert group_exists(raw, "parents")
    assert not group_exists(raw, "missing")
    assert set(groups_map(raw)) == {"parents", "kids"}


def test_permissions_wrapped():
    raw = json.loads(
        '{"permissions": {"synapse.main": {}, "synapse.family_dashboard": {}}}'
    )
    assert permission_exists(raw, "synapse.family_dashboard")
    assert not permission_exists(raw, "core_family.main")
    assert "synapse.main" in permissions_map(raw)


def test_users_wrapped():
    raw = json.loads(
        '{"users": {"alice": {"username": "alice", "groups": ["federation-test"]}}}'
    )
    assert "alice" in users_map(raw)
    assert users_map(raw)["alice"]["groups"] == ["federation-test"]
