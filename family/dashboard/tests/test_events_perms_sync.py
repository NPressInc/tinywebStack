"""Gap 2b: PUT /permissions and PUT /api/permissions run TWS_EVENTS_PERMS_CMD."""

import json
import subprocess

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app
from tinywebstack_dashboard.app_devices import create_device, init_db, mint_device_token


@pytest.fixture
def perms_env(tmp_path, monkeypatch):
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
    init_db(devices_db)
    from tinywebstack_permissions.store import PermissionsDB, default_role_seed_files

    with PermissionsDB(db_path) as db:
        db.seed_roles([p for p in default_role_seed_files() if p.is_file()])
        db.set_role("@kid1:family-a.test", "kid", username="kid1", server_name="family-a.test")
        db.set_role("@parent1:family-a.test", "parent", username="parent1", server_name="family-a.test")
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
    return TestClient(create_app(cfg))


def _parent_token():
    t = mint_device_token()
    create_device(username="parent1", role="parent", device_name="P", platform="ios", token=t)
    return t


def test_put_permissions_invokes_events_perms_cmd(perms_env, monkeypatch):
    calls = []
    monkeypatch.setenv("TWS_EVENTS_PERMS_CMD", "echo events-sync")

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(subprocess, "run", fake_run)
    client = perms_env
    token = _parent_token()
    for path in ("/permissions/kid1", "/api/permissions/kid1"):
        calls.clear()
        r = client.put(
            path,
            headers={"Authorization": f"Bearer {token}"},
            json={"events_enabled": True},
        )
        assert r.status_code == 200
        assert calls and calls[0][:2] == ["echo", "events-sync"]
