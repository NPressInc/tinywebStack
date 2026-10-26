"""Gap 2a: new members seed permissions.db and family-policy.json immediately."""

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app
from tinywebstack_dashboard.app_devices import init_db, mint_device_token
from tinywebstack_dashboard.app_devices import create_device
from tinywebstack_permissions.store import PermissionsDB, SqliteFamilyPolicyStore


@pytest.fixture
def seed_env(tmp_path, monkeypatch):
    policy = tmp_path / "family-policy.json"
    db_path = tmp_path / "permissions.db"
    devices_db = tmp_path / "app-devices.db"
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-a.test",
                "kids": {"@kid1:family-a.test": {"events_enabled": True}},
                "parent_mxids": ["@parent1:family-a.test"],
                "trusted_domains": [],
                "reject_encryption": True,
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setenv("TWS_PERMISSIONS_DB", str(db_path))
    monkeypatch.setenv("TWS_APP_DEVICES_DB", str(devices_db))
    monkeypatch.setenv("TWS_INVITE_SECRET", "test-invite-secret")
    init_db(devices_db)
    from tinywebstack_permissions.store import default_role_seed_files

    with PermissionsDB(db_path) as db:
        db.seed_roles([p for p in default_role_seed_files() if p.is_file()])
        db.set_role("@kid1:family-a.test", "kid", username="kid1", server_name="family-a.test")
        db.set_role("@parent1:family-a.test", "parent", username="parent1", server_name="family-a.test")
        db.set_server_name("family-a.test")
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_GROUPS",
        json.dumps({"parents": ["parent1"], "kids": ["kid1"]}),
    )
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="family-a.test",
        csrf_secret="test-secret",
    )
    client = TestClient(create_app(cfg))
    return client, policy, db_path


def _parent_token(client):
    t = mint_device_token()
    create_device(
        username="parent1",
        role="parent",
        device_name="P",
        platform="ios",
        token=t,
    )
    return t


def test_post_api_members_seeds_kid_in_policy_and_db(seed_env):
    client, policy_path, db_path = seed_env
    token = _parent_token(client)
    r = client.post(
        "/api/members",
        headers={"Authorization": f"Bearer {token}"},
        json={"username": "sam", "role": "kid", "display_name": "Sam"},
    )
    assert r.status_code == 200
    mxid = "@sam:family-a.test"
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
    assert mxid in policy["kids"]
    with PermissionsDB(db_path) as db:
        ps = db.get_permissions("sam")
        assert ps is not None
        assert ps.role == "kid"
    store = SqliteFamilyPolicyStore(policy_path, db_path=db_path)
    assert mxid in store.policy.kids


def test_post_api_members_seeds_parent_in_policy_and_db(seed_env):
    client, policy_path, db_path = seed_env
    token = _parent_token(client)
    r = client.post(
        "/api/members",
        headers={"Authorization": f"Bearer {token}"},
        json={"username": "pat", "role": "parent", "display_name": "Pat"},
    )
    assert r.status_code == 200
    mxid = "@pat:family-a.test"
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
    assert mxid in policy["parent_mxids"]
    with PermissionsDB(db_path) as db:
        ps = db.get_permissions("pat")
        assert ps is not None
        assert ps.role == "parent"


def test_create_family_member_helper_seeds_policy(seed_env):
    _, policy_path, db_path = seed_env
    from tinywebstack_dashboard.member_ops import create_family_member

    cfg = DashboardConfig(
        policy_path=str(policy_path),
        server_name="family-a.test",
        csrf_secret="test-secret",
    )
    create_family_member(
        cfg,
        username="lea",
        role="kid",
        display_name="Lea",
        issue_enroll_code=False,
        enroll_issued_by="parent1",
    )
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
    assert "@lea:family-a.test" in policy["kids"]
    with PermissionsDB(db_path) as db:
        assert db.get_permissions("lea") is not None
