import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app


@pytest.fixture
def calendar_client(tmp_path, monkeypatch):
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
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_GROUPS", json.dumps({"parents": ["parent1"], "kids": []}))
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="family-a.test",
        csrf_secret="test-secret",
        caldav_root="https://nextcloud.family-a.test/nextcloud/remote.php/dav",
    )
    app = create_app(cfg)
    client = TestClient(app)
    client.headers.update({"YNH_USER": "parent1"})
    return client


def test_calendar_page_shows_caldav_root(calendar_client) -> None:
    r = calendar_client.get("/calendar")
    assert r.status_code == 200
    assert "nextcloud.family-a.test" in r.text
    assert "Phone calendars" in r.text


def test_calendar_qr_png(calendar_client) -> None:
    r = calendar_client.get("/calendar/qr.png")
    assert r.status_code == 200
    assert r.headers["content-type"] == "image/png"
