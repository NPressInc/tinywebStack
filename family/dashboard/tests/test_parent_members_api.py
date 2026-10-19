"""Parent JSON API for members, invites, and permissions bearer auth."""

import json

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app
from tinywebstack_dashboard.app_devices import create_device, init_db, mint_device_token


@pytest.fixture
def parent_api_env(tmp_path, monkeypatch):
    policy = tmp_path / "family-policy.json"
    db_path = tmp_path / "permissions.db"
    devices_db = tmp_path / "app-devices.db"
    pending = tmp_path / "pending-invites.json"
    pending.write_text(
        json.dumps(
            {
                "invites": {
                    "abc123": {"created_by": "parent1", "issuer": "family-a.test"},
                    "used1": {
                        "created_by": "parent1",
                        "issuer": "family-a.test",
                        "used": True,
                    },
                }
            }
        ),
        encoding="utf-8",
    )
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
    monkeypatch.setenv("TWS_PENDING_INVITES_PATH", str(pending))
    monkeypatch.setenv("TWS_INVITE_SECRET", "test-invite-secret")
    monkeypatch.setenv("TWS_PUBLIC_BASE_URL", "https://family-a.test/family")
    init_db(devices_db)
    from tinywebstack_permissions.store import PermissionsDB, default_role_seed_files

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
    return client, devices_db, pending


def _parent_bearer(client):
    t = mint_device_token()
    create_device(
        username="parent1",
        role="parent",
        device_name="P",
        platform="ios",
        token=t,
    )
    return t


def _kid_bearer(client):
    t = mint_device_token()
    create_device(
        username="kid1",
        role="kid",
        device_name="K",
        platform="android",
        token=t,
    )
    return t


def _auth(token=None, ynh=None):
    h = {}
    if token:
        h["Authorization"] = f"Bearer {token}"
    if ynh:
        h["YNH_USER"] = ynh
    return h


def test_post_members_returns_password_no_store(parent_api_env):
    client, _, _ = parent_api_env
    token = _parent_bearer(client)
    r = client.post(
        "/api/members",
        headers=_auth(token=token),
        json={"username": "sam", "role": "kid", "display_name": "Sam"},
    )
    assert r.status_code == 200
    assert r.headers.get("cache-control") == "no-store"
    body = r.json()
    assert body["username"] == "sam"
    assert len(body["password"]) >= 12
    assert "enroll_code" not in body


def test_post_members_optional_enroll_code(parent_api_env):
    client, _, _ = parent_api_env
    token = _parent_bearer(client)
    r = client.post(
        "/api/members",
        headers=_auth(token=token),
        json={
            "username": "mia",
            "role": "kid",
            "issue_enroll_code": True,
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["enroll_code"]
    assert body["enroll_qr_payload"].startswith("tinyweb://enroll?")


def test_post_members_kid_forbidden(parent_api_env):
    client, _, _ = parent_api_env
    t_kid = _kid_bearer(client)
    r = client.post(
        "/api/members",
        headers=_auth(token=t_kid),
        json={"username": "x", "role": "kid"},
    )
    assert r.status_code == 403


def test_reset_password_no_store_revokes_devices(parent_api_env):
    client, _, _ = parent_api_env
    token = _parent_bearer(client)
    t_kid = mint_device_token()
    create_device(
        username="kid1",
        role="kid",
        device_name="Phone",
        platform="android",
        token=t_kid,
    )
    r = client.post(
        "/api/members/kid1/reset-password",
        headers=_auth(token=token),
    )
    assert r.status_code == 200
    assert r.headers.get("cache-control") == "no-store"
    assert len(r.json()["password"]) >= 12
    assert client.get("/api/app/me", headers=_auth(token=t_kid)).status_code == 401


def test_delete_member_rules(parent_api_env):
    client, _, _ = parent_api_env
    token = _parent_bearer(client)
    assert (
        client.delete("/api/members/parent1", headers=_auth(token=token)).status_code == 400
    )
    r = client.delete("/api/members/kid1", headers=_auth(token=token))
    assert r.status_code == 200
    assert r.headers.get("cache-control") == "no-store"
    assert r.json()["username"] == "kid1"


def test_delete_member_last_parent(parent_api_env, monkeypatch):
    client, _, _ = parent_api_env
    token = _parent_bearer(client)
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_GROUPS",
        json.dumps({"parents": ["parent1", "parent2"], "kids": ["kid1"]}),
    )
    r = client.delete("/api/members/parent2", headers=_auth(token=token))
    assert r.status_code == 200
    assert (
        client.delete("/api/members/parent1", headers=_auth(token=token)).status_code == 400
    )


def test_enroll_code_and_devices(parent_api_env):
    client, _, _ = parent_api_env
    token = _parent_bearer(client)
    t_kid = mint_device_token()
    create_device(
        username="kid1",
        role="kid",
        device_name="KidPhone",
        platform="android",
        token=t_kid,
    )
    r = client.post("/api/members/kid1/enroll-code", headers=_auth(token=token))
    assert r.status_code == 200
    assert r.headers.get("cache-control") == "no-store"
    assert r.json()["code"]

    listed = client.get("/api/members/kid1/devices", headers=_auth(token=token))
    assert listed.status_code == 200
    assert len(listed.json()) == 1
    dev_id = listed.json()[0]["id"]
    rev = client.post(
        f"/api/members/kid1/devices/{dev_id}/revoke",
        headers=_auth(token=token),
    )
    assert rev.status_code == 200
    assert rev.headers.get("cache-control") == "no-store"


def test_invites_create_and_delete(parent_api_env):
    client, _, pending = parent_api_env
    token = _parent_bearer(client)
    r = client.post("/api/invites", headers=_auth(token=token))
    assert r.status_code == 200
    assert r.headers.get("cache-control") == "no-store"
    body = r.json()
    assert body["token"]
    assert body["nonce"]
    assert "redeem?token=" in body["invite_url"]
    nonce = body["nonce"]
    assert client.delete(f"/api/invites/{nonce}", headers=_auth(token=token)).status_code == 200
    data = json.loads(pending.read_text(encoding="utf-8"))
    assert nonce not in data["invites"]
    assert client.delete("/api/invites/abc123", headers=_auth(token=token)).status_code == 200
    assert client.delete("/api/invites/missing", headers=_auth(token=token)).status_code == 404


def test_invites_kid_forbidden(parent_api_env):
    client, _, _ = parent_api_env
    t_kid = _kid_bearer(client)
    assert client.post("/api/invites", headers=_auth(token=t_kid)).status_code == 403
    assert (
        client.delete("/api/invites/abc123", headers=_auth(token=t_kid)).status_code == 403
    )


def test_permissions_parent_bearer(parent_api_env):
    client, _, _ = parent_api_env
    token = _parent_bearer(client)
    r = client.get("/permissions/kid1", headers=_auth(token=token))
    assert r.status_code == 200
    assert r.json()["role"] == "kid"
    r2 = client.put(
        "/permissions/kid1",
        headers=_auth(token=token),
        json={"events_enabled": False},
    )
    assert r2.status_code == 200
    assert r2.json()["events_enabled"] is False


def test_permissions_kid_bearer_denied(parent_api_env):
    client, _, _ = parent_api_env
    t_kid = _kid_bearer(client)
    assert client.get("/permissions/kid1", headers=_auth(token=t_kid)).status_code == 403
    assert (
        client.put(
            "/permissions/kid1",
            headers=_auth(token=t_kid),
            json={"events_enabled": False},
        ).status_code
        == 403
    )
