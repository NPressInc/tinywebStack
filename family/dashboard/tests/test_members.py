import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app
from tinywebstack_dashboard.owntracks_setup import build_owntracks_config, owntracks_otcp_link


@pytest.fixture
def member_client(tmp_path, monkeypatch):
    policy = tmp_path / "family-policy.json"
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-a.test",
                "kids": {"@kid1:family-a.test": {}},
                "parent_mxids": ["@parent1:family-a.test"],
                "trusted_domains": [],
                "reject_encryption": True,
            }
        ),
        encoding="utf-8",
    )
    ot_store = tmp_path / "owntracks-kids.json"
    ot_store.write_text(
        json.dumps(
            {
                "kid1": {
                    "device_id": "kid1-phone",
                    "username": "kid1",
                    "password": "secret",
                    "publish_url": "https://owntracks.family-a.test/api/",
                    "tracker_id": "k1",
                }
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_GROUPS", json.dumps({"parents": ["parent1"], "kids": ["kid1"]}))
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="family-a.test",
        csrf_secret="test-secret",
        location_base_url="https://owntracks.family-a.test/",
        location_domain="owntracks.family-a.test",
        owntracks_store_path=str(ot_store),
    )
    return TestClient(create_app(cfg)), ot_store


def test_members_page(member_client):
    c, _ = member_client
    r = c.get("/members", headers={"Remote-User": "parent1"})
    assert r.status_code == 200
    assert "kid1" in r.text and "parent1" in r.text


def test_add_member(member_client):
    c, _ = member_client
    page = c.get("/members/add", headers={"Remote-User": "parent1"})
    import re

    csrf = re.search(r'name="csrf" value="([^"]+)"', page.text).group(1)
    r = c.post(
        "/members/add",
        headers={"Remote-User": "parent1"},
        data={"csrf": csrf, "username": "sam", "full_name": "Sam", "role": "kid"},
    )
    assert r.status_code == 200
    assert "sam" in r.text.lower()


def test_location_qr(member_client):
    c, _ = member_client
    r = c.get("/members/kid1/location/qr.png", headers={"Remote-User": "parent1"})
    assert r.status_code == 200
    assert r.headers["content-type"] == "image/png"


def test_owntracks_link():
    cfg = build_owntracks_config(
        "https://loc.test/api/",
        "kid1",
        "pass",
        "kid1-phone",
        "k1",
    )
    link = owntracks_otcp_link(cfg)
    assert link.startswith("owntracks:///config?c=")
