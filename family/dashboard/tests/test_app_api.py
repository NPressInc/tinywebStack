import json
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app
from tinywebstack_dashboard.app_devices import (
    create_device,
    create_enroll_code,
    init_db,
    mint_device_token,
    record_enroll_failure,
)


@pytest.fixture
def app_env(tmp_path, monkeypatch):
    policy = tmp_path / "family-policy.json"
    db_path = tmp_path / "permissions.db"
    devices_db = tmp_path / "app-devices.db"
    pending = tmp_path / "pending-invites.json"
    pending.write_text(
        json.dumps(
            {
                "invites": {
                    "abc123": {"created_by": "parent1", "issuer": "family-a.test"},
                    "used1": {"created_by": "parent1", "issuer": "family-a.test", "used": True},
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
    monkeypatch.setenv("TWS_APP_CODE_TTL_S", "600")
    init_db(devices_db)
    from tinywebstack_permissions.store import PermissionsDB, default_role_seed_files

    with PermissionsDB(db_path) as db:
        db.seed_roles([p for p in default_role_seed_files() if p.is_file()])
        db.set_role("@kid1:family-a.test", "kid", username="kid1", server_name="family-a.test")
        db.set_role("@parent1:family-a.test", "parent", username="parent1", server_name="family-a.test")
        db.set_server_name("family-a.test")
        db.set_permission(
            "@kid1:family-a.test",
            "quiet_hours",
            {
                "start": "21:00",
                "end": "07:00",
                "timezone": "UTC",
                "days": list(range(7)),
            },
        )
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_GROUPS",
        json.dumps({"parents": ["parent1"], "kids": ["kid1"]}),
    )
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="family-a.test",
        csrf_secret="test-secret",
        location_base_url="https://loc.example/",
        location_domain="loc.example",
        events_base_url="https://events.example/",
        caldav_root="https://nc.example/dav",
    )
    app = create_app(cfg)
    client = TestClient(app)
    return client, devices_db, db_path


def _enroll_code(client, username="kid1"):
    r = client.post(
        "/api/app/codes",
        headers={"YNH_USER": "parent1"},
        json={"username": username},
    )
    assert r.status_code == 200
    return r.json()["code"]


def test_well_known_fields(app_env):
    client, _, _ = app_env
    r = client.get("/.well-known/tinywebstack-family.json")
    assert r.status_code == 200
    data = r.json()
    assert data["app_api_version"] == 1
    assert data["dashboard_base"] == "/family"
    assert data["enroll_url"] == "/family/api/app/enroll"
    assert data["matrix_homeserver_url"].startswith("https://")
    assert data["caldav_root"]
    assert data["element_x_deeplink_base"] == "https://matrix.to/#/"


def test_code_create_parent_only(app_env):
    client, _, _ = app_env
    assert client.post("/api/app/codes", json={"username": "kid1"}).status_code == 401
    assert (
        client.post(
            "/api/app/codes",
            headers={"YNH_USER": "kid1"},
            json={"username": "kid1"},
        ).status_code
        == 403
    )
    assert (
        client.post(
            "/api/app/codes",
            headers={"YNH_USER": "parent1"},
            json={"username": "nobody"},
        ).status_code
        == 404
    )
    r = client.post(
        "/api/app/codes",
        headers={"YNH_USER": "parent1"},
        json={"username": "kid1"},
    )
    assert r.status_code == 200
    body = r.json()
    assert len(body["code"]) == 8
    assert body["qr_payload"].startswith("tinyweb://enroll?")


def test_enroll_by_code_single_use_and_expiry(app_env, monkeypatch):
    client, devices_db, _ = app_env
    code = _enroll_code(client)
    payload = {
        "method": "code",
        "code": code,
        "device_name": "Phone",
        "platform": "android",
    }
    r = client.post("/api/app/enroll", json=payload)
    assert r.status_code == 200
    assert r.headers.get("cache-control") == "no-store"
    assert "dashboard" in r.json()
    assert r.json()["matrix"]["status"] == "not_provisioned"
    r2 = client.post("/api/app/enroll", json=payload)
    assert r2.status_code == 401
    assert r2.json()["error"] == "invalid_credentials"

    code2 = _enroll_code(client)
    import hashlib
    from tinywebstack_dashboard.app_devices import _connect

    ch2 = hashlib.sha256(code2.encode("utf-8")).hexdigest()
    with _connect(devices_db) as conn:
        conn.execute(
            "UPDATE enroll_codes SET expires_at = ? WHERE code_hash = ?",
            ("2000-01-01T00:00:00+00:00", ch2),
        )
    r3 = client.post(
        "/api/app/enroll",
        json={
            "method": "code",
            "code": code2,
            "device_name": "Phone2",
            "platform": "ios",
        },
    )
    assert r3.status_code == 401


def test_enroll_rate_limit(app_env):
    client, _, _ = app_env
    ip = "203.0.113.9"
    for _ in range(5):
        client.post(
            "/api/app/enroll",
            json={
                "method": "code",
                "code": "BADCODE1",
                "device_name": "x",
                "platform": "other",
            },
            headers={"X-Real-IP": ip},
        )
    r = client.post(
        "/api/app/enroll",
        json={
            "method": "code",
            "code": "BADCODE2",
            "device_name": "x",
            "platform": "other",
        },
        headers={"X-Real-IP": ip},
    )
    assert r.status_code == 429


def test_enroll_rate_limit_ignores_spoofed_x_forwarded_for(app_env):
    client, _, _ = app_env
    real_ip = "203.0.113.10"
    for i in range(5):
        client.post(
            "/api/app/enroll",
            json={
                "method": "code",
                "code": f"SPOOF{i}",
                "device_name": "x",
                "platform": "other",
            },
            headers={
                "X-Real-IP": real_ip,
                "X-Forwarded-For": f"198.51.100.{i}",
            },
        )
    r = client.post(
        "/api/app/enroll",
        json={
            "method": "code",
            "code": "SPOOFX",
            "device_name": "x",
            "platform": "other",
        },
        headers={
            "X-Real-IP": real_ip,
            "X-Forwarded-For": "203.0.113.255",
        },
    )
    assert r.status_code == 429


def test_enroll_rate_limit_skips_ip_bucket_for_unknown(app_env):
    from tinywebstack_dashboard.app_devices import enroll_rate_limited, record_enroll_failure

    for i in range(10):
        user = f"u{i}"
        assert not enroll_rate_limited("unknown", user)
        record_enroll_failure("unknown", user)


def test_enroll_password_matrix_mock(app_env, monkeypatch):
    client, _, _ = app_env

    def fake_urlopen(req, timeout=0, context=None):
        class Resp:
            def read(self):
                return json.dumps(
                    {
                        "access_token": "mx_tok",
                        "device_id": "DEV123",
                        "user_id": "@kid1:family-a.test",
                    }
                ).encode()

            def __enter__(self):
                return self

            def __exit__(self, *a):
                pass

        return Resp()

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    r = client.post(
        "/api/app/enroll",
        json={
            "method": "password",
            "username": "kid1",
            "password": "secret",
            "device_name": "Tab",
            "platform": "android",
        },
    )
    assert r.status_code == 200
    assert r.json()["matrix"]["status"] == "ok"
    assert r.json()["matrix"]["device_id"] == "DEV123"


def test_enroll_forbidden_non_family(app_env, monkeypatch):
    client, _, _ = app_env

    def fake_urlopen(req, timeout=0, context=None):
        class Resp:
            def read(self):
                return json.dumps(
                    {
                        "access_token": "mx_tok",
                        "device_id": "DEVX",
                        "user_id": "@stranger:family-a.test",
                    }
                ).encode()

            def __enter__(self):
                return self

            def __exit__(self, *a):
                pass

        return Resp()

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    r = client.post(
        "/api/app/enroll",
        json={
            "method": "password",
            "username": "stranger",
            "password": "secret",
            "device_name": "Tab",
            "platform": "android",
        },
    )
    assert r.status_code == 403


def test_bearer_me_and_revoke(app_env):
    client, _, _ = app_env
    code = _enroll_code(client)
    en = client.post(
        "/api/app/enroll",
        json={
            "method": "code",
            "code": code,
            "device_name": "KidPhone",
            "platform": "ios",
        },
    )
    token = en.json()["dashboard"]["token"]
    me = client.get("/api/app/me", headers={"Authorization": f"Bearer {token}"})
    assert me.status_code == 200
    assert me.json()["username"] == "kid1"
    assert me.json()["role"] == "kid"
    rev = client.post(
        f"/api/app/devices/{en.json()['device_id']}/revoke",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert rev.status_code == 200
    assert client.get("/api/app/me", headers={"Authorization": f"Bearer {token}"}).status_code == 401


def test_devices_parent_sees_all_kid_sees_own(app_env):
    client, devices_db, _ = app_env
    t1 = mint_device_token()
    create_device(
        username="kid1",
        role="kid",
        device_name="A",
        platform="android",
        token=t1,
    )
    t2 = mint_device_token()
    create_device(
        username="parent1",
        role="parent",
        device_name="P",
        platform="ios",
        token=t2,
    )
    kid_list = client.get("/api/app/devices", headers={"Authorization": f"Bearer {t1}"})
    assert kid_list.status_code == 200
    assert len(kid_list.json()) == 1
    assert "token_hash" not in json.dumps(kid_list.json())
    parent_list = client.get("/api/app/devices", headers={"Authorization": f"Bearer {t2}"})
    assert len(parent_list.json()) == 2


def test_parent_revoke_device(app_env):
    client, _, _ = app_env
    code = _enroll_code(client, "kid1")
    en = client.post(
        "/api/app/enroll",
        json={
            "method": "code",
            "code": code,
            "device_name": "KidPhone",
            "platform": "ios",
        },
    )
    device_id = en.json()["device_id"]
    t_parent = mint_device_token()
    create_device(
        username="parent1",
        role="parent",
        device_name="Parent",
        platform="ios",
        token=t_parent,
    )
    r = client.post(
        f"/api/app/devices/{device_id}/revoke",
        headers={"Authorization": f"Bearer {t_parent}"},
    )
    assert r.status_code == 200


def test_password_reset_revokes_devices(app_env):
    client, devices_db, _ = app_env
    t = mint_device_token()
    create_device(
        username="kid1",
        role="kid",
        device_name="X",
        platform="android",
        token=t,
    )
    page = client.get("/members/kid1", headers={"YNH_USER": "parent1"})
    import re

    m = re.search(r'name="csrf" value="([^"]+)"', page.text)
    csrf = m.group(1)
    client.post(
        "/members/kid1/reset-password",
        headers={"YNH_USER": "parent1"},
        data={"csrf": csrf},
    )
    assert client.get("/api/app/me", headers={"Authorization": f"Bearer {t}"}).status_code == 401


def test_members_and_invites_parent_only(app_env):
    client, _, _ = app_env
    assert client.get("/api/members").status_code == 401
    assert client.get("/api/invites").status_code == 401
    t_kid = mint_device_token()
    create_device(username="kid1", role="kid", device_name="k", platform="android", token=t_kid)
    assert (
        client.get("/api/members", headers={"Authorization": f"Bearer {t_kid}"}).status_code == 403
    )
    r = client.get("/api/members", headers={"YNH_USER": "parent1"})
    assert r.status_code == 200
    assert any(m["username"] == "kid1" for m in r.json())
    inv = client.get("/api/invites", headers={"YNH_USER": "parent1"})
    assert inv.status_code == 200
    assert len(inv.json()) == 1
    assert "token" not in json.dumps(inv.json()).lower()


def test_quiet_hours_active_inactive(app_env, monkeypatch):
    client, _, _ = app_env
    t = mint_device_token()
    create_device(username="kid1", role="kid", device_name="k", platform="android", token=t)
    monkeypatch.setenv("TWS_APP_QUIET_HOURS_NOW", "2026-06-15T22:00:00+00:00")
    active = client.get("/api/app/me", headers={"Authorization": f"Bearer {t}"})
    assert active.json()["quiet_hours"]["active"] is True
    monkeypatch.setenv("TWS_APP_QUIET_HOURS_NOW", "2026-06-15T12:00:00+00:00")
    inactive = client.get("/api/app/me", headers={"Authorization": f"Bearer {t}"})
    assert inactive.json()["quiet_hours"]["active"] is False
    t_parent = mint_device_token()
    create_device(
        username="parent1",
        role="parent",
        device_name="p",
        platform="ios",
        token=t_parent,
    )
    parent_me = client.get("/api/app/me", headers={"Authorization": f"Bearer {t_parent}"})
    assert parent_me.json()["quiet_hours"]["configured"] is False
