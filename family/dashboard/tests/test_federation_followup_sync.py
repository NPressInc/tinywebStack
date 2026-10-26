"""Gap 3: delayed second federation sync after schedule / blocking accept."""

import json
import subprocess
import threading
import time

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app
from tinywebstack_dashboard.app_devices import create_device, init_db, mint_device_token
from tinywebstack_family.invite import create_invite_token


@pytest.fixture
def fed_followup_env(tmp_path, monkeypatch):
    policy = tmp_path / "family-policy.json"
    state = tmp_path / "federation-state.json"
    pending = tmp_path / "pending-invites.json"
    pending.write_text(json.dumps({"invites": {}}), encoding="utf-8")
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-b.test",
                "kids": {},
                "parent_mxids": ["@parent1:family-b.test"],
                "trusted_domains": [],
                "reject_encryption": True,
            }
        ),
        encoding="utf-8",
    )
    state.write_text(json.dumps({"version": 1, "trusted_domains": []}), encoding="utf-8")
    monkeypatch.setenv("TWS_FEDERATION_STATE_PATH", str(state))
    monkeypatch.setenv("TWS_FEDERATION_SYNC_CMD", "echo federation-sync")
    monkeypatch.setenv("TWS_FEDERATION_FOLLOWUP_DELAY_SEC", "0")
    monkeypatch.setenv("TWS_PENDING_INVITES_PATH", str(pending))
    monkeypatch.setenv("TWS_INVITE_SECRET", "issuer-secret")
    monkeypatch.setenv("TWS_APP_DEVICES_DB", str(tmp_path / "app-devices.db"))
    init_db(tmp_path / "app-devices.db")
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_GROUPS",
        json.dumps({"parents": ["parent1"], "kids": []}),
    )
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="family-b.test",
        csrf_secret="test-secret",
    )
    return TestClient(create_app(cfg))


def _wait_for_calls(calls, lock, minimum: int, timeout: float = 2.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        with lock:
            if len(calls) >= minimum:
                return
        time.sleep(0.05)
    with lock:
        assert len(calls) >= minimum


def test_schedule_federation_sync_runs_followup_pass(fed_followup_env, monkeypatch):
    calls = []
    lock = threading.Lock()

    def fake_run(cmd, **kwargs):
        with lock:
            calls.append(list(cmd))
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(subprocess, "run", fake_run)
    fed_followup_env.post(
        "/federation/domains",
        headers={"YNH_USER": "parent1"},
        json={"domain": "peer.test"},
    )
    _wait_for_calls(calls, lock, 2)
    with lock:
        assert all(c[:2] == ["echo", "federation-sync"] for c in calls)


def test_link_invite_accept_blocking_sync_runs_followup(fed_followup_env, monkeypatch):
    from unittest.mock import patch

    calls = []
    lock = threading.Lock()

    def fake_run(cmd, **kwargs):
        with lock:
            calls.append(list(cmd))
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(subprocess, "run", fake_run)
    token, _ = create_invite_token("family-a.test", "issuer-secret")
    t = mint_device_token()
    create_device(
        username="parent1",
        role="parent",
        device_name="P",
        platform="ios",
        token=t,
    )
    verify_resp = {
        "issuer_domain": "family-a.test",
        "matrix_server": "family-a.test",
        "matrix_server_key": {"old_verify_keys": {}},
    }
    with patch(
        "tinywebstack_dashboard.link_invite.post_json",
        return_value=verify_resp,
    ), patch(
        "tinywebstack_dashboard.link_invite.verify_peer_domain",
        return_value={"old_verify_keys": {}},
    ):
        r = fed_followup_env.post(
            "/api/link-invites/accept",
            headers={"Authorization": f"Bearer {t}"},
            json={"token": token},
        )
    assert r.status_code == 200
    _wait_for_calls(calls, lock, 2)
