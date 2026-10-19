"""JSON API for incoming link invites (preview, accept, decline, linked-families)."""

import json
from pathlib import Path
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app
from tinywebstack_dashboard.app_devices import create_device, init_db, mint_device_token
from tinywebstack_family.invite import create_invite_token


@pytest.fixture
def link_invite_env(tmp_path, monkeypatch):
    policy = tmp_path / "family-policy.json"
    state = tmp_path / "federation-state.json"
    db_path = tmp_path / "permissions.db"
    devices_db = tmp_path / "app-devices.db"
    pending = tmp_path / "pending-invites.json"
    pending.write_text(json.dumps({"invites": {}}), encoding="utf-8")
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-b.test",
                "kids": {"@kid1:family-b.test": {"events_enabled": True}},
                "parent_mxids": ["@parent1:family-b.test"],
                "trusted_domains": [],
                "reject_encryption": True,
            }
        ),
        encoding="utf-8",
    )
    state.write_text(
        json.dumps({"version": 1, "trusted_domains": []}),
        encoding="utf-8",
    )
    monkeypatch.setenv("TWS_PERMISSIONS_DB", str(db_path))
    monkeypatch.setenv("TWS_APP_DEVICES_DB", str(devices_db))
    monkeypatch.setenv("TWS_PENDING_INVITES_PATH", str(pending))
    monkeypatch.setenv("TWS_INVITE_SECRET", "issuer-secret")
    monkeypatch.setenv("TWS_FEDERATION_STATE_PATH", str(state))
    monkeypatch.setenv("TWS_PUBLIC_BASE_URL", "https://family-b.test/family")
    init_db(devices_db)
    from tinywebstack_permissions.store import PermissionsDB, default_role_seed_files

    with PermissionsDB(db_path) as db:
        db.seed_roles([p for p in default_role_seed_files() if p.is_file()])
        db.set_role("@kid1:family-b.test", "kid", username="kid1", server_name="family-b.test")
        db.set_role("@parent1:family-b.test", "parent", username="parent1", server_name="family-b.test")
        db.set_server_name("family-b.test")
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_GROUPS",
        json.dumps({"parents": ["parent1"], "kids": ["kid1"]}),
    )
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    monkeypatch.setenv("TWS_FEDERATION_SYNC_CMD", "true")
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="family-b.test",
        csrf_secret="test-secret",
    )
    client = TestClient(create_app(cfg))
    return client, pending, policy, state


def _parent_bearer():
    t = mint_device_token()
    create_device(
        username="parent1",
        role="parent",
        device_name="P",
        platform="ios",
        token=t,
    )
    return t


def _kid_bearer():
    t = mint_device_token()
    create_device(
        username="kid1",
        role="kid",
        device_name="K",
        platform="android",
        token=t,
    )
    return t


def _auth(token=None):
    return {"Authorization": f"Bearer {token}"} if token else {}


def _outgoing_token(issuer: str = "family-a.test", secret: str = "issuer-secret") -> str:
    token, _ = create_invite_token(issuer, secret)
    return token


def test_preview_does_not_consume_nonce(link_invite_env):
    client, pending, _, _ = link_invite_env
    token, _ = create_invite_token("family-a.test", "issuer-secret")
    parent = _parent_bearer()
    well_known = {"server_name": "family-a.test", "family_name": "Family A"}

    with patch(
        "tinywebstack_dashboard.link_invite.fetch_inviter_well_known",
        return_value=(well_known, True),
    ), patch("tinywebstack_dashboard.link_invite.post_json") as mock_post:
        r = client.post(
            "/api/link-invites/preview",
            headers=_auth(parent),
            json={"token": token},
        )
        r2 = client.post(
            "/api/link-invites/preview",
            headers=_auth(parent),
            json={"token": token},
        )
    assert r.status_code == 200 and r2.status_code == 200
    assert r.headers.get("cache-control") == "no-store"
    body = r.json()
    assert body["inviter_domain"] == "family-a.test"
    assert body["inviter_family_name"] == "Family A"
    assert body["already_linked"] is False
    assert body["reachable"] is True
    mock_post.assert_not_called()
    assert pending.read_text(encoding="utf-8") == json.dumps({"invites": {}})


def test_preview_self_link_400(link_invite_env):
    client, _, _, _ = link_invite_env
    token = _outgoing_token("family-b.test", "issuer-secret")
    parent = _parent_bearer()
    r = client.post(
        "/api/link-invites/preview",
        headers=_auth(parent),
        json={"token": token},
    )
    assert r.status_code == 400
    assert "yourself" in r.json()["detail"].lower()


def test_link_invites_kid_forbidden(link_invite_env):
    client, _, _, _ = link_invite_env
    kid = _kid_bearer()
    token = _outgoing_token()
    for path in (
        "/api/link-invites/preview",
        "/api/link-invites/accept",
        "/api/link-invites/decline",
        "/api/linked-families",
    ):
        method = "get" if path.endswith("families") else "post"
        if method == "get":
            r = client.get(path, headers=_auth(kid))
        else:
            r = client.post(path, headers=_auth(kid), json={"token": token})
        assert r.status_code == 403


def test_accept_calls_shared_redeem(link_invite_env):
    client, _, policy, _ = link_invite_env
    parent = _parent_bearer()
    token = _outgoing_token()
    verify_resp = {
        "issuer_domain": "family-a.test",
        "matrix_server": "family-a.test",
        "matrix_server_key": {"old_verify_keys": {}},
    }

    with patch(
        "tinywebstack_dashboard.link_invite.post_json",
        return_value=verify_resp,
    ) as mock_post, patch(
        "tinywebstack_dashboard.link_invite.verify_peer_domain",
        return_value={"old_verify_keys": {}},
    ):
        r = client.post(
            "/api/link-invites/accept",
            headers=_auth(parent),
            json={"token": token},
        )
    assert r.status_code == 200
    mock_post.assert_called_once()
    body = r.json()
    assert body["linked_domain"] == "family-a.test"
    assert body["synapse_federation"] == "ok"
    assert body["mobilizon_relay"] == "ok"
    policy_data = json.loads(policy.read_text(encoding="utf-8"))
    assert "family-a.test" in policy_data["trusted_domains"]


def test_accept_already_linked_409(link_invite_env):
    client, _, policy, _ = link_invite_env
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-b.test",
                "kids": {},
                "parent_mxids": [],
                "trusted_domains": ["family-a.test"],
            }
        ),
        encoding="utf-8",
    )
    parent = _parent_bearer()
    token = _outgoing_token()
    with patch("tinywebstack_dashboard.link_invite.post_json") as mock_post:
        r = client.post(
            "/api/link-invites/accept",
            headers=_auth(parent),
            json={"token": token},
        )
    assert r.status_code == 409
    mock_post.assert_not_called()
    assert r.json()["already_linked"] is True


def test_decline_calls_remote_best_effort(link_invite_env):
    client, _, _, _ = link_invite_env
    parent = _parent_bearer()
    token = _outgoing_token()
    with patch("tinywebstack_dashboard.link_invite.post_json") as mock_post:
        r = client.post(
            "/api/link-invites/decline",
            headers=_auth(parent),
            json={"token": token},
        )
    assert r.status_code == 200
    assert r.json()["declined"] is True
    mock_post.assert_called_once()
    assert mock_post.call_args[0][0].endswith("/api/invite/decline")


def test_invite_decline_public(tmp_path, monkeypatch):
    pending = tmp_path / "pending-a.json"
    token, nonce = create_invite_token("family-a.test", "issuer-secret")
    pending.write_text(
        json.dumps({"invites": {nonce: {"issuer": "family-a.test"}}}),
        encoding="utf-8",
    )
    monkeypatch.setenv("TWS_PENDING_INVITES_PATH", str(pending))
    monkeypatch.setenv("TWS_INVITE_SECRET", "issuer-secret")
    policy = tmp_path / "policy-a.json"
    policy.write_text(
        json.dumps({"server_name": "family-a.test", "trusted_domains": [], "kids": {}}),
        encoding="utf-8",
    )
    cfg = DashboardConfig(policy_path=str(policy), server_name="family-a.test", csrf_secret="x")
    issuer_client = TestClient(create_app(cfg))
    r = issuer_client.post("/api/invite/decline", json={"token": token})
    assert r.status_code == 200
    assert json.loads(pending.read_text(encoding="utf-8"))["invites"] == {}


def test_linked_families_list(link_invite_env):
    client, _, policy, state = link_invite_env
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-b.test",
                "kids": {},
                "trusted_domains": ["family-a.test"],
            }
        ),
        encoding="utf-8",
    )
    state.write_text(
        json.dumps({"version": 1, "trusted_domains": ["family-a.test"]}),
        encoding="utf-8",
    )
    parent = _parent_bearer()
    with patch(
        "tinywebstack_dashboard.link_invite.fetch_inviter_well_known",
        return_value=({"server_name": "family-a.test"}, True),
    ):
        r = client.get("/api/linked-families", headers=_auth(parent))
    assert r.status_code == 200
    families = r.json()["linked_families"]
    assert len(families) == 1
    assert families[0]["domain"] == "family-a.test"
