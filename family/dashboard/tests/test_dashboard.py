import json
import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app


@pytest.fixture
def client(tmp_path, monkeypatch):
    policy = tmp_path / "family-policy.json"
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-a.test",
                "kids": {},
                "parent_mxids": [],
                "trusted_domains": [],
                "reject_encryption": True,
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_GROUPS",
        json.dumps({"parents": ["parent1"], "kids": ["kid1"]}),
    )
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_LIST_USERS",
        json.dumps(
            {
                "users": {
                    "parent1": {"groups": ["parents"]},
                    "kid1": {"groups": ["kids"]},
                }
            }
        ),
    )
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="family-a.test",
        csrf_secret="test-secret",
        location_base_url="https://owntracks.example/",
    )
    app = create_app(cfg)
    return TestClient(app), policy


def test_auth_required(client):
    c, _ = client
    assert c.get("/", headers={"Remote-User": "parent1"}).status_code == 401


def test_parent_can_list_kids(client):
    c, policy = client
    r = c.get("/", headers={"YNH_USER": "parent1"})
    assert r.status_code == 200
    assert "@kid1:family-a.test" in r.text


def test_non_parent_forbidden(client):
    c, _ = client
    r = c.get("/", headers={"YNH_USER": "kid1"})
    assert r.status_code == 403


def test_save_allowlist(client):
    c, policy = client
    kid = "@kid1:family-a.test"
    page = c.get(f"/kid/{kid}", headers={"YNH_USER": "parent1"})
    assert page.status_code == 200
    # Extract csrf from form (hidden input)
    import re

    m = re.search(r'name="csrf" value="([^"]+)"', page.text)
    assert m
    csrf = m.group(1)
    r = c.post(
        f"/kid/{kid}",
        headers={"YNH_USER": "parent1"},
        data={
            "csrf": csrf,
            "allowlist_mxids": "@friend:family-b.test",
            "allowlist_domains": "family-b.test",
            "qh_start": "21:00",
            "qh_end": "07:00",
            "qh_timezone": "UTC",
        },
        follow_redirects=False,
    )
    assert r.status_code == 303
    data = json.loads(policy.read_text())
    entry = data["kids"][kid]
    assert "@friend:family-b.test" in entry["allowlist_mxids"]
    assert entry["quiet_hours"]["start"] == "21:00"
