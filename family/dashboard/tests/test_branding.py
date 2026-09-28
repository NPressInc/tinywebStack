"""TinyWeb dashboard branding smoke tests."""

import json

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
    monkeypatch.setenv("TWS_DASHBOARD_ROOT_PATH", "/family")
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_GROUPS",
        json.dumps({"parents": ["parent1"], "kids": []}),
    )
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_LIST_USERS",
        json.dumps({"users": {"parent1": {"groups": ["parents"]}}}),
    )
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="family-a.test",
        csrf_secret="test-secret",
    )
    return TestClient(create_app(cfg))


def test_home_shows_tinyweb_branding(client):
    r = client.get("/", headers={"YNH_USER": "parent1"})
    assert r.status_code == 200
    assert "TinyWeb" in r.text
    assert "/family/static/tinyweb/tinyweb.css" in r.text
    assert "YunoHost" not in r.text


def test_static_css_served(client):
    r = client.get("/static/tinyweb/tinyweb.css")
    assert r.status_code == 200, r.text
    assert "--tw-blue-deep" in r.text
