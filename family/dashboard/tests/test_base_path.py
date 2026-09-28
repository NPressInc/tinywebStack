"""Ensure dashboard links stay under the /family URL prefix."""

import json
import re

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app

_HREF = re.compile(r"""href="(/[^"]*)""")
_SRC = re.compile(r"""src="(/[^"]*)""")


@pytest.fixture
def client(tmp_path, monkeypatch):
    policy = tmp_path / "family-policy.json"
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-a.test",
                "kids": {"@kid1:family-a.test": {"allowlist_mxids": []}},
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
        json.dumps({"parents": ["parent1"], "kids": ["kid1"]}),
    )
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_LIST_USERS",
        json.dumps({"users": {"parent1": {"groups": ["parents"]}, "kid1": {"groups": ["kids"]}}}),
    )
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="family-a.test",
        csrf_secret="test-secret",
    )
    return TestClient(create_app(cfg))


def _root_relative_hrefs(html: str) -> list[str]:
    return [m.group(1) for m in _HREF.finditer(html) if m.group(1).startswith("/")]


def test_index_links_under_family_prefix(client):
    r = client.get("/", headers={"YNH_USER": "parent1"})
    assert r.status_code == 200
    for href in _root_relative_hrefs(r.text):
        assert href.startswith("/family/") or href == "/family/", f"bad href: {href}"


def test_members_redirect_under_family_prefix(client):
    r = client.get("/members", headers={"YNH_USER": "parent1"})
    assert r.status_code == 200
    for href in _root_relative_hrefs(r.text):
        assert href.startswith("/family/") or href == "/family/"


def test_member_location_img_src_under_family_prefix(tmp_path, monkeypatch):
    policy = tmp_path / "family-policy.json"
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-a.test",
                "kids": {"@kid1:family-a.test": {"allowlist_mxids": []}},
                "parent_mxids": [],
                "trusted_domains": [],
                "reject_encryption": True,
            }
        ),
        encoding="utf-8",
    )
    store = tmp_path / "owntracks-kids.json"
    store.write_text(
        json.dumps(
            {
                "kid1": {
                    "device_id": "kid1-phone",
                    "username": "kid1",
                    "password": "secret",
                    "publish_url": "https://loc.test/recorder/pub",
                    "tracker_id": "ki",
                }
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setenv("TWS_DASHBOARD_ROOT_PATH", "/family")
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_GROUPS",
        json.dumps({"parents": ["parent1"], "kids": ["kid1"]}),
    )
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="family-a.test",
        csrf_secret="test-secret",
        owntracks_store_path=str(store),
    )
    client = TestClient(create_app(cfg))
    r = client.get("/members/kid1/location", headers={"YNH_USER": "parent1"})
    assert r.status_code == 200
    for src in [m.group(1) for m in _SRC.finditer(r.text) if m.group(1).startswith("/")]:
        assert src.startswith("/family/"), f"bad img src: {src}"
