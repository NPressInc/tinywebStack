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
    get_device,
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
    ot_store = tmp_path / "owntracks-kids.json"
    ot_store.write_text(
        json.dumps(
            {
                "kid1": {
                    "device_id": "kid1-phone",
                    "username": "kid1",
                    "password": "stored-ot-pass",
                    "publish_url": "https://loc.example/recorder/pub",
                    "tracker_id": "k1",
                }
            }
        ),
        encoding="utf-8",
    )
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="family-a.test",
        csrf_secret="test-secret",
        location_base_url="https://loc.example/",
        location_domain="loc.example",
        events_base_url="https://events.example/",
        caldav_root="https://nc.example/dav",
        owntracks_store_path=str(ot_store),
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
    assert r.json()["matrix"]["status"] == "unavailable"
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


def test_enroll_by_code_matrix_ticket_login(app_env, monkeypatch, tmp_path):
    client, _, _ = app_env
    secret_file = tmp_path / "ticket.secret"
    secret_file.write_bytes(b"\x11" * 32)
    monkeypatch.setenv("TWS_MATRIX_LOGIN_TICKET_SECRET_FILE", str(secret_file))
    captured = []

    def fake_urlopen(req, timeout=0, context=None):
        captured.append(json.loads(req.data.decode("utf-8")))
        class Resp:
            def read(self):
                return json.dumps(
                    {
                        "access_token": "mx_code_tok",
                        "device_id": "DEVCODE",
                        "user_id": "@kid1:family-a.test",
                    }
                ).encode()

            def __enter__(self):
                return self

            def __exit__(self, *a):
                pass

        return Resp()

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    code = _enroll_code(client)
    r = client.post(
        "/api/app/enroll",
        json={
            "method": "code",
            "code": code,
            "device_name": "Phone",
            "platform": "android",
        },
    )
    assert r.status_code == 200
    assert r.json()["matrix"]["status"] == "ok"
    assert r.json()["matrix"]["device_id"] == "DEVCODE"
    assert captured[0]["type"] == "org.tinywebstack.login_ticket"
    assert captured[0]["identifier"]["user"] == "kid1"
    assert "ticket" in captured[0]


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
    deleted = []

    def fake_matrix_delete(user, server_name, device_id):
        deleted.append((user, server_name, device_id))

    monkeypatch.setattr(
        "tinywebstack_dashboard.app_api.matrix_device_delete",
        fake_matrix_delete,
    )

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
    assert deleted == [("stranger", "family-a.test", "DEVX")]


def test_enroll_password_unknown_user_401_and_rate_limit(app_env, monkeypatch):
    import urllib.error

    client, _, _ = app_env
    ip = "203.0.113.50"

    def fake_urlopen(req, timeout=0, context=None):
        raise urllib.error.HTTPError(req.full_url, 403, "Forbidden", {}, None)

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    payload = {
        "method": "password",
        "username": "nobody",
        "password": "wrong",
        "device_name": "Tab",
        "platform": "android",
    }
    for _ in range(5):
        r = client.post("/api/app/enroll", json=payload, headers={"X-Real-IP": ip})
        assert r.status_code == 401
        assert r.json()["error"] == "invalid_credentials"
    r6 = client.post("/api/app/enroll", json=payload, headers={"X-Real-IP": ip})
    assert r6.status_code == 429


def test_enroll_password_synapse_throttle_is_429_not_failure(app_env, monkeypatch):
    import io
    import urllib.error

    client, _, _ = app_env
    ip = "203.0.113.51"

    def fake_urlopen(req, timeout=0, context=None):
        body = io.BytesIO(b'{"errcode":"M_LIMIT_EXCEEDED","retry_after_ms":7000}')
        raise urllib.error.HTTPError(req.full_url, 429, "Too Many Requests", {}, body)

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    payload = {"method": "password", "username": "alice", "password": "x", "device_name": "T", "platform": "ios"}
    for _ in range(7):
        r = client.post("/api/app/enroll", json=payload, headers={"X-Real-IP": ip})
        assert r.status_code == 429
        assert r.json()["error"] == "rate_limited"
        assert r.headers["Retry-After"] == "7"


def test_enroll_kid_owntracks_publish_http_mode(app_env):
    client, _, _ = app_env
    code = _enroll_code(client)
    r = client.post(
        "/api/app/enroll",
        json={
            "method": "code",
            "code": code,
            "device_name": "Phone",
            "platform": "android",
        },
    )
    assert r.status_code == 200
    ot = r.json()["owntracks"]
    assert ot["publish"] is True
    assert ot["mode"] == "http"


def test_enroll_kid_returns_stored_owntracks_without_issue(app_env, monkeypatch):
    client, _, _ = app_env
    calls = []

    def track_issue(*args, **kwargs):
        calls.append(args)
        raise AssertionError("issue_owntracks should not be called")

    monkeypatch.setattr("tinywebstack_dashboard.app_api.issue_owntracks", track_issue)
    code = _enroll_code(client)
    r = client.post(
        "/api/app/enroll",
        json={
            "method": "code",
            "code": code,
            "device_name": "Phone",
            "platform": "android",
        },
    )
    assert r.status_code == 200
    ot = r.json()["owntracks"]
    assert ot["device"] == "kid1-phone"
    assert ot["url"] == "https://loc.example/recorder/pub"
    assert ot["tid"] == "k1"
    assert calls == []


def test_enroll_kid_issues_owntracks_when_missing(app_env, monkeypatch, tmp_path):
    client, _, _ = app_env
    empty_store = tmp_path / "empty-ot.json"
    empty_store.write_text("{}", encoding="utf-8")
    monkeypatch.setattr(
        "tinywebstack_dashboard.app_api.load_stored_credentials",
        lambda _path, user: None,
    )
    issued = []

    def fake_issue(user, main_domain, location_domain):
        issued.append((user, main_domain, location_domain))
        return {
            "url": "https://loc.example/new",
            "user": user,
            "device": f"{user}-phone",
            "password": "new-ot",
            "tid": "ab",
        }

    monkeypatch.setattr("tinywebstack_dashboard.app_api.issue_owntracks", fake_issue)
    code = _enroll_code(client)
    r = client.post(
        "/api/app/enroll",
        json={
            "method": "code",
            "code": code,
            "device_name": "Phone",
            "platform": "android",
        },
    )
    assert r.status_code == 200
    assert len(issued) == 1
    assert issued[0][0] == "kid1"
    assert r.json()["owntracks"]["device"] == "kid1-phone"


def test_revoke_does_not_touch_owntracks(app_env, monkeypatch):
    client, _, _ = app_env
    calls = []

    def track_issue(*args, **kwargs):
        calls.append(args)
        raise AssertionError("issue_owntracks should not be called on revoke")

    monkeypatch.setattr("tinywebstack_dashboard.app_api.issue_owntracks", track_issue)
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
    rev = client.post(
        f"/api/app/devices/{en.json()['device_id']}/revoke",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert rev.status_code == 200
    assert calls == []


def test_enroll_stores_full_nextcloud_token_name(app_env):
    client, _, _ = app_env
    code = _enroll_code(client)
    device_name = "My Pixel 9"
    r = client.post(
        "/api/app/enroll",
        json={
            "method": "code",
            "code": code,
            "device_name": device_name,
            "platform": "android",
        },
    )
    assert r.status_code == 200
    dev = get_device(r.json()["device_id"])
    assert dev.nextcloud_token_name == f"TinyWeb {device_name}"


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


def test_locations_parent_kids_only(app_env, monkeypatch):
    client, _, _ = app_env
    token = _parent_token(client)

    def fake_last():
        return (
            [
                {
                    "username": "kid1",
                    "device": "kid1-phone",
                    "lat": 40.0,
                    "lon": -105.0,
                    "acc": 12,
                    "batt": 80,
                    "tst": 1_700_000_000,
                    "tid": "k1",
                    "_type": "location",
                },
                {
                    "username": "stranger",
                    "device": "x",
                    "lat": 1.0,
                    "lon": 2.0,
                    "tst": 1_700_000_001,
                    "_type": "location",
                },
            ],
            True,
        )

    monkeypatch.setattr("tinywebstack_dashboard.app_api.fetch_all_last", fake_last)
    r = client.get("/api/locations", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    kids = r.json()["kids"]
    assert len(kids) == 1
    assert kids[0]["username"] == "kid1"
    assert kids[0]["lat"] == 40.0
    assert "status" not in r.json()


def test_locations_kid_forbidden(app_env):
    client, _, _ = app_env
    t_kid = mint_device_token()
    create_device(username="kid1", role="kid", device_name="k", platform="android", token=t_kid)
    assert (
        client.get("/api/locations", headers={"Authorization": f"Bearer {t_kid}"}).status_code
        == 403
    )


def test_locations_unauthenticated_401(app_env):
    client, _, _ = app_env
    assert client.get("/api/locations").status_code == 401


def test_locations_recorder_unavailable(app_env, monkeypatch):
    client, _, _ = app_env
    token = _parent_token(client)
    monkeypatch.setattr(
        "tinywebstack_dashboard.app_api.fetch_all_last",
        lambda: (None, False),
    )
    r = client.get("/api/locations", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.json() == {"kids": [], "status": "unavailable"}


def test_locations_track_capped(app_env, monkeypatch):
    client, _, _ = app_env
    token = _parent_token(client)

    def fake_track(user, device, hours):
        points = [
            {
                "lat": float(i),
                "lon": 0.0,
                "tst": i,
                "_type": "location",
            }
            for i in range(2500)
        ]
        return points, True

    monkeypatch.setattr("tinywebstack_dashboard.app_api.fetch_track", fake_track)
    r = client.get(
        "/api/locations/kid1/track?hours=24",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
    assert len(r.json()["points"]) == 2000


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


def test_map_unavailable_without_data(app_env, monkeypatch, tmp_path):
    client, _, _ = app_env
    monkeypatch.setenv("TWS_MAP_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("TWS_PUBLIC_BASE_URL", "https://family-a.test/family")
    token = _parent_token(client)
    r = client.get("/api/map", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    data = r.json()
    assert data["available"] is False
    assert data["attribution"] == "© OpenStreetMap contributors, Protomaps"
    assert "tiles_url" in data


def test_map_available_with_pmtiles(app_env, monkeypatch, tmp_path):
    client, _, _ = app_env
    monkeypatch.setenv("TWS_MAP_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("TWS_PUBLIC_BASE_URL", "https://family-a.test/family")
    (tmp_path / "basemap.pmtiles").write_bytes(b"pmtiles-test")
    (tmp_path / "map.meta.json").write_text(
        json.dumps(
            {
                "bounds": [-109.0, 39.0, -104.0, 41.0],
                "maxzoom": 14,
                "flavor": "light",
            }
        ),
        encoding="utf-8",
    )
    token = _parent_token(client)
    r = client.get("/api/map", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    data = r.json()
    assert data["available"] is True
    assert data["bounds"] == [-109.0, 39.0, -104.0, 41.0]
    assert data["tiles_url"].startswith("https://family-a.test/family/tiles/")
    assert "t=" in data["tiles_url"]
    assert "t=" in data["glyphs_url"]


def test_map_kid_forbidden(app_env, monkeypatch, tmp_path):
    client, _, _ = app_env
    monkeypatch.setenv("TWS_MAP_DATA_DIR", str(tmp_path))
    t_kid = mint_device_token()
    create_device(username="kid1", role="kid", device_name="k", platform="android", token=t_kid)
    assert client.get("/api/map", headers={"Authorization": f"Bearer {t_kid}"}).status_code == 403


def test_map_tile_serve_with_bearer(app_env, monkeypatch, tmp_path):
    client, _, _ = app_env
    monkeypatch.setenv("TWS_MAP_DATA_DIR", str(tmp_path))
    (tmp_path / "basemap.pmtiles").write_bytes(b"tile-bytes")
    token = _parent_token(client)
    r = client.get(
        "/tiles/basemap.pmtiles",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 200
    assert r.content == b"tile-bytes"
    assert r.headers.get("accept-ranges") == "bytes"
