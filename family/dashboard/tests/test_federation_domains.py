"""L2.2 trusted-domain management integration tests.

FastAPI TestClient against the real create_app() — auth, CRUD, persistence,
plus a DRY_RUN test of scripts/vm/synapse-federation-allowlist.sh rendering
Synapse yaml from a fixture federation-state.json.
"""

import base64
import json
import subprocess
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app
from tinywebstack_dashboard.federation import reconcile_state_with_policy

REPO_ROOT = Path(__file__).resolve().parents[3]
ALLOWLIST_SCRIPT = REPO_ROOT / "scripts" / "vm" / "synapse-federation-allowlist.sh"

PARENT = "parent1"
HEADERS = {"YNH_USER": PARENT}


@pytest.fixture
def fed_env(tmp_path, monkeypatch):
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
    state = tmp_path / "federation-state.json"
    nodes_conf = tmp_path / "nodes.conf"
    nodes_conf.write_text(
        "# NAME DOMAIN RAM VCPUS DISK\n"
        "family-a family-a.test 4096 2 32\n"
        "family-b family-b.test 4096 2 32\n",
        encoding="utf-8",
    )
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_GROUPS", json.dumps({"parents": [PARENT], "kids": ["kid1"]})
    )
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    monkeypatch.setenv("TWS_FEDERATION_STATE_PATH", str(state))
    monkeypatch.delenv("TWS_FEDERATION_SYNC_CMD", raising=False)

    def make_cfg() -> DashboardConfig:
        return DashboardConfig(
            policy_path=str(policy),
            server_name="family-a.test",
            csrf_secret="test-secret",
        )

    def make_client() -> TestClient:
        return TestClient(create_app(make_cfg()))

    monkeypatch.setenv("TW_NODES_CONF", str(nodes_conf))
    return make_client, make_cfg, state, policy, nodes_conf


def _router_client(fed_env):
    make_client, _, _, _, _ = fed_env
    return make_client()


def test_federation_get_requires_auth(fed_env):
    c = _router_client(fed_env)
    assert c.get("/federation/domains").status_code == 401


def test_federation_non_parent_forbidden(fed_env):
    c = _router_client(fed_env)
    r = c.get("/federation/domains", headers={"YNH_USER": "mallory"})
    assert r.status_code == 403
    r = c.post(
        "/federation/domains", headers={"YNH_USER": "mallory"}, json={"domain": "evil.test"}
    )
    assert r.status_code == 403
    r = c.delete("/federation/domains/evil.test", headers={"YNH_USER": "mallory"})
    assert r.status_code == 403


def test_reconcile_seeds_state_from_legacy_policy(fed_env, tmp_path):
    _, _, state, policy, _ = fed_env
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-a.test",
                "kids": {},
                "parent_mxids": [],
                "trusted_domains": ["family-b.test", "family-c.test"],
                "reject_encryption": True,
            }
        ),
        encoding="utf-8",
    )
    merged = reconcile_state_with_policy(state, policy, server_name="family-a.test")
    assert merged == ["family-b.test", "family-c.test"]
    on_disk = json.loads(state.read_text(encoding="utf-8"))
    assert on_disk["trusted_domains"] == ["family-b.test", "family-c.test"]


def test_add_domain_unions_with_policy_peers(fed_env):
    make_client, _, state, policy, _ = fed_env
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-a.test",
                "kids": {},
                "parent_mxids": [],
                "trusted_domains": ["family-b.test"],
                "reject_encryption": True,
            }
        ),
        encoding="utf-8",
    )
    c = make_client()
    r = c.post("/federation/domains", headers=HEADERS, json={"domain": "family-c.test"})
    assert r.status_code == 200
    body = c.get("/federation/domains", headers=HEADERS).json()
    assert body["trusted_domains"] == ["family-b.test", "family-c.test"]
    saved = json.loads(state.read_text(encoding="utf-8"))
    assert saved["trusted_domains"] == ["family-b.test", "family-c.test"]
    assert json.loads(policy.read_text(encoding="utf-8"))["trusted_domains"] == [
        "family-b.test",
        "family-c.test",
    ]


def test_add_list_remove_roundtrip(fed_env):
    make_client, _, state, policy, _ = fed_env
    c = make_client()
    r = c.post("/federation/domains", headers=HEADERS, json={"domain": "Family-B.Test"})
    assert r.status_code == 200
    assert r.json()["created"] is True

    r = c.get("/federation/domains", headers=HEADERS)
    assert r.status_code == 200
    body = r.json()
    assert body["trusted_domains"] == ["family-b.test"]
    assert {"name": "family-b", "domain": "family-b.test"} in body["peer_nodes"]
    assert all(n["domain"] != "family-a.test" for n in body["peer_nodes"])

    # State file persisted + legacy policy trusted_domains mirrored.
    on_disk = json.loads(state.read_text(encoding="utf-8"))
    assert on_disk["trusted_domains"] == ["family-b.test"]
    assert json.loads(policy.read_text(encoding="utf-8"))["trusted_domains"] == ["family-b.test"]

    r = c.delete("/federation/domains/family-b.test", headers=HEADERS)
    assert r.status_code == 200
    assert r.json()["removed"] == "family-b.test"
    assert c.get("/federation/domains", headers=HEADERS).json()["trusted_domains"] == []
    assert json.loads(policy.read_text(encoding="utf-8"))["trusted_domains"] == []


def test_duplicate_add_is_idempotent(fed_env):
    make_client, _, state, _, _ = fed_env
    c = make_client()
    assert c.post("/federation/domains", headers=HEADERS, json={"domain": "peer.test"}).json()["created"] is True
    r = c.post("/federation/domains", headers=HEADERS, json={"domain": "peer.test"})
    assert r.status_code == 200
    assert r.json()["created"] is False
    saved = json.loads(state.read_text(encoding="utf-8"))
    assert saved["trusted_domains"] == ["peer.test"]


@pytest.mark.parametrize(
    "bad",
    [
        "",
        "   ",
        "not a domain",
        "https://evil.test/",
        "evil.test/path",
        "bad..domain.test",
        ".leading.test",
        "trailing.dot.test.",
        ";rm -rf /",
        "up**er.test",
        "a" * 64 + ".test",
    ],
)
def test_malformed_domain_rejected(fed_env, bad):
    make_client = fed_env[0]
    c = make_client()
    r = c.post("/federation/domains", headers=HEADERS, json={"domain": bad})
    assert r.status_code == 400, f"{bad!r} should be rejected"


def test_own_domain_cannot_be_added_or_removed(fed_env):
    make_client = fed_env[0]
    c = make_client()
    r = c.post("/federation/domains", headers=HEADERS, json={"domain": "family-a.test"})
    assert r.status_code == 400
    r = c.delete("/federation/domains/family-a.test", headers=HEADERS)
    assert r.status_code == 409


def test_delete_unknown_domain_404(fed_env):
    make_client = fed_env[0]
    c = make_client()
    assert c.delete("/federation/domains/nope.test", headers=HEADERS).status_code == 404


def test_state_survives_app_restart(fed_env):
    make_client, _, _, _, _ = fed_env
    c1 = make_client()
    assert c1.post(
        "/federation/domains", headers=HEADERS, json={"domain": "peer.test:8448"}
    ).status_code == 200
    # Fresh app instance reloads the persisted state file from disk.
    c2 = make_client()
    body = c2.get("/federation/domains", headers=HEADERS).json()
    assert body["trusted_domains"] == ["peer.test:8448"]


def _run_allowlist_dry_run(args, env_extra=None):
    import os

    env = dict(os.environ)
    env["DRY_RUN"] = "1"
    env.pop("FEDERATION_IP_RANGE_WHITELIST", None)
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(
        ["bash", str(ALLOWLIST_SCRIPT), *args],
        capture_output=True,
        text=True,
        timeout=60,
        env=env,
    )
    return proc


def _fixture_state(tmp_path):
    state = tmp_path / "federation-state.json"
    state.write_text(
        json.dumps(
            {
                "version": 1,
                "updated_at": "2026-09-30T00:00:00+00:00",
                "trusted_domains": ["family-b.test", "family-c.test", "family-a.test"],
            }
        ),
        encoding="utf-8",
    )
    return state


def test_allowlist_from_state_dry_run_yaml(tmp_path):
    pytest.importorskip("yaml")
    import yaml

    state = _fixture_state(tmp_path)
    proc = _run_allowlist_dry_run(["--from-state", "family-a.test", str(state)])
    assert proc.returncode == 0, proc.stderr
    doc = yaml.safe_load(proc.stdout)
    # Local domain excluded, peers sorted and quoted.
    assert doc["federation_domain_whitelist"] == ["family-b.test", "family-c.test"]
    assert doc["ip_range_whitelist"] == ["192.168.122.0/24"]


def test_allowlist_from_state_base64_dry_run_yaml(tmp_path):
    pytest.importorskip("yaml")
    import yaml

    state = _fixture_state(tmp_path)
    b64 = base64.b64encode(state.read_bytes()).decode()
    proc = _run_allowlist_dry_run(["--from-state", "family-a.test", f"base64:{b64}"])
    assert proc.returncode == 0, proc.stderr
    doc = yaml.safe_load(proc.stdout)
    assert doc["federation_domain_whitelist"] == ["family-b.test", "family-c.test"]


def test_allowlist_static_mode_unchanged_dry_run(tmp_path):
    pytest.importorskip("yaml")
    import yaml

    proc = _run_allowlist_dry_run(["family-a.test", "family-b.test"])
    assert proc.returncode == 0, proc.stderr
    doc = yaml.safe_load(proc.stdout)
    assert doc["federation_domain_whitelist"] == ["family-b.test"]
    assert doc["ip_range_whitelist"] == ["192.168.122.0/24"]
    assert "# Managed by tinywebStack" in proc.stdout


def test_allowlist_missing_state_file_fails(tmp_path):
    proc = _run_allowlist_dry_run(
        ["--from-state", "family-a.test", str(tmp_path / "absent.json")]
    )
    assert proc.returncode != 0
    assert "Missing federation state file" in proc.stderr + proc.stdout


def test_allowlist_empty_state_refuses_open_whitelist(tmp_path):
    # An empty trusted_domains list would render federation_domain_whitelist
    # as YAML null (= allow-all). The script must refuse instead.
    state = tmp_path / "federation-state.json"
    state.write_text(
        json.dumps({"version": 1, "trusted_domains": ["family-a.test"]}),
        encoding="utf-8",
    )
    proc = _run_allowlist_dry_run(["--from-state", "family-a.test", str(state)])
    assert proc.returncode != 0
    assert "refusing to render an open whitelist" in proc.stderr + proc.stdout
