"""Post-setup Jellyfin host updates go through the claim token, then apply.

The fake provider never looks published, so apply refuses. A publishing provider
can add and remove the host. The setup code is not read.
"""

from __future__ import annotations

import json
import os
import socket
import stat
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

import uvicorn

ROOT = Path(__file__).resolve().parents[2]
HOSTS = ROOT / "scripts" / "cloudflared-hosts.sh"
INSTALL = ROOT / "scripts" / "vm" / "install-jellyfin.sh"
OPERATOR = "operator-test-token"

sys.path.insert(0, str(ROOT / "controlplane"))

from tinyweb_controlplane.app import create_app  # noqa: E402
from tinyweb_controlplane.config import Settings  # noqa: E402
from tinyweb_controlplane.providers import EdgeCertificate, FakeProvider, IssuedTunnel  # noqa: E402


class Publishing:
    publishes = True
    name = "cloudflare"

    def __init__(self) -> None:
        self.create_calls = 0

    def create_tunnel(self, spec):
        self.create_calls += 1
        return IssuedTunnel(
            tunnel_id="00000000-0000-4000-8000-0000000000bb",
            account_tag="account",
            token="live-tunnel-token-example",
            credentials_file={"TunnelID": "00000000-0000-4000-8000-0000000000bb"},
            name=spec.name,
        )

    def delete_tunnel(self, tunnel_id: str) -> None:
        return None

    def upsert_cname(self, record) -> None:
        return None

    def delete_cname(self, name: str) -> None:
        return None

    def update_ingress(self, tunnel_id: str, spec) -> None:
        return None

    def ensure_edge_certificate(self, request):
        return EdgeCertificate(
            method=request.method,
            hosts=list(request.hosts),
            status="active",
            pack_id="pack",
            ready=True,
        )


def _plane(tmp_path: Path, provider):
    settings = Settings(
        db_path=str(tmp_path / "cp.sqlite"),
        operator_token=OPERATOR,
        provider_name="fake",
        base_domain="tinyweb.win",
        public_origin="https://tinyweb.win",
    )
    app = create_app(settings, provider=provider)
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    for _ in range(100):
        if server.started:
            break
        time.sleep(0.05)
    else:
        raise AssertionError("control plane did not start")
    return f"http://127.0.0.1:{port}", server


def _stop(server: uvicorn.Server) -> None:
    server.should_exit = True


def _json(url: str, payload: dict | None = None, bearer: str | None = None) -> dict:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {}
    if data is not None:
        headers["Content-Type"] = "application/json"
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    request = urllib.request.Request(url, data=data, headers=headers, method="POST" if data is not None else "GET")
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.loads(response.read().decode("utf-8"))


def _prepare(base: str, etc: Path, *, jellyfin: bool) -> tuple[str, str, str]:
    minted = _json(base + "/v1/operator/units", {}, bearer=OPERATOR)
    claimed = _json(
        base + "/v1/setup/claim",
        {"setup_code": minted["setup_code"], "slug": "smith"},
    )
    issued = _json(
        base + "/v1/tunnels",
        {"jellyfin": jellyfin},
        bearer=claimed["claim_token"],
    )
    cloud = etc / "cloudflared"
    cloud.mkdir(parents=True)
    claim = cloud / "claim-token"
    claim.write_text(claimed["claim_token"] + "\n", encoding="utf-8")
    claim.chmod(0o600)
    handoff = cloud / "handoff.json"
    handoff.write_text(json.dumps(issued) + "\n", encoding="utf-8")
    handoff.chmod(0o600)
    (cloud / "control-plane.url").write_text(base + "\n", encoding="utf-8")
    return minted["setup_code"], claimed["claim_token"], issued["tunnel"]["token"]


def _run(etc: Path, dest: Path, *args: str, url: str = "", jellyfin_env: str | None = None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["TWS_ETC_DIR"] = str(etc)
    env["TWS_SETUP_CLOUDFLARED_DEST"] = str(dest)
    env.pop("TWS_CONTROL_PLANE_URL", None)
    if url:
        env["TWS_CONTROL_PLANE_URL"] = url
    if jellyfin_env is not None:
        env["TWS_JELLYFIN"] = jellyfin_env
    return subprocess.run(
        ["bash", str(HOSTS), *args],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_missing_handoff_does_not_call_the_control_plane(tmp_path: Path) -> None:
    etc = tmp_path / "etc"
    etc.mkdir()
    proc = _run(etc, tmp_path / "dest", "--jellyfin", "1", url="http://127.0.0.1:9")
    assert proc.returncode == 0, proc.stderr
    assert "No tunnel handoff yet" in proc.stderr
    assert "published=" not in proc.stdout
    assert not (tmp_path / "dest" / "tunnel.env").exists()


def test_fake_provider_refuses_apply_and_does_not_print_the_token(tmp_path: Path) -> None:
    base, server = _plane(tmp_path, FakeProvider())
    etc = tmp_path / "etc"
    dest = tmp_path / "dest"
    try:
        code, claim_token, tunnel_token = _prepare(base, etc, jellyfin=False)
        proc = _run(etc, dest, "--jellyfin", "1", url=base)
    finally:
        _stop(server)
    assert proc.returncode != 0
    assert "published=false" in proc.stderr
    blob = proc.stdout + proc.stderr
    assert code not in blob
    assert claim_token not in blob
    assert tunnel_token not in blob
    assert "immich" not in blob
    assert not (dest / "tunnel.env").exists()
    saved = json.loads((etc / "cloudflared" / "handoff.json").read_text(encoding="utf-8"))
    assert saved["published"] is False
    assert "jellyfin.smith.tinyweb.win" in [row["name"] for row in saved["dns"]]


def test_publishing_provider_adds_and_removes_the_host(tmp_path: Path) -> None:
    provider = Publishing()
    base, server = _plane(tmp_path, provider)
    etc = tmp_path / "etc"
    dest = tmp_path / "dest"
    try:
        code, claim_token, tunnel_token = _prepare(base, etc, jellyfin=False)
        added = _run(etc, dest, "--jellyfin", "1")
        assert added.returncode == 0, added.stderr
        saved = json.loads((etc / "cloudflared" / "handoff.json").read_text(encoding="utf-8"))
        assert saved["published"] is True
        assert "jellyfin.smith.tinyweb.win" in [row["name"] for row in saved["dns"]]
        row = next(item for item in saved["dns"] if item["name"] == "jellyfin.smith.tinyweb.win")
        assert row["proxied"] is True
        assert row["type"] == "CNAME"
        env_file = dest / "tunnel.env"
        assert env_file.is_file()
        assert stat.S_IMODE(env_file.stat().st_mode) == 0o600
        blob = added.stdout + added.stderr
        assert "jellyfin_host=present" in added.stdout
        assert code not in blob
        assert claim_token not in blob
        assert tunnel_token not in blob
        assert provider.create_calls == 1

        removed = _run(etc, dest, "--jellyfin", "0")
        assert removed.returncode == 0, removed.stderr
        after = json.loads((etc / "cloudflared" / "handoff.json").read_text(encoding="utf-8"))
        assert after["published"] is True
        assert "jellyfin.smith.tinyweb.win" not in [row["name"] for row in after["dns"]]
        assert "matrix.smith.tinyweb.win" in [row["name"] for row in after["dns"]]
        assert "jellyfin_host=absent" in removed.stdout
        assert tunnel_token not in removed.stdout + removed.stderr
        assert provider.create_calls == 1
    finally:
        _stop(server)


def test_turning_jellyfin_off_removes_the_host_without_yunohost(tmp_path: Path) -> None:
    provider = Publishing()
    base, server = _plane(tmp_path, provider)
    etc = tmp_path / "etc"
    dest = tmp_path / "dest"
    try:
        _code, _claim, tunnel_token = _prepare(base, etc, jellyfin=True)
        env = os.environ.copy()
        env.update(
            {
                "TWS_ETC_DIR": str(etc),
                "TWS_JELLYFIN": "0",
                "TWS_CONTROL_PLANE_URL": base,
                "TWS_SETUP_CLOUDFLARED_DEST": str(dest),
                "TW_STACK_SKIP_LOCAL_ENV": "1",
            }
        )
        proc = subprocess.run(
            ["bash", str(INSTALL), "smith.tinyweb.win"],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
    finally:
        _stop(server)
    assert proc.returncode == 0, proc.stderr
    assert "Jellyfin install skipped" in proc.stderr
    assert "yunohost app install" not in proc.stderr
    assert tunnel_token not in proc.stdout + proc.stderr
    saved = json.loads((etc / "cloudflared" / "handoff.json").read_text(encoding="utf-8"))
    assert saved["published"] is True
    assert "jellyfin.smith.tinyweb.win" not in [row["name"] for row in saved["dns"]]
    assert (dest / "tunnel.env").is_file()


def test_unset_jellyfin_does_not_remove_a_host(tmp_path: Path) -> None:
    provider = Publishing()
    base, server = _plane(tmp_path, provider)
    etc = tmp_path / "etc"
    dest = tmp_path / "dest"
    try:
        _code, _claim, tunnel_token = _prepare(base, etc, jellyfin=True)
        env = os.environ.copy()
        env.pop("TWS_JELLYFIN", None)
        env.update(
            {
                "TWS_ETC_DIR": str(etc),
                "TWS_CONTROL_PLANE_URL": base,
                "TWS_SETUP_CLOUDFLARED_DEST": str(dest),
                "TW_STACK_SKIP_LOCAL_ENV": "1",
            }
        )
        proc = subprocess.run(
            ["bash", str(INSTALL), "smith.tinyweb.win"],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
    finally:
        _stop(server)
    assert proc.returncode == 0, proc.stderr
    assert "Jellyfin install skipped" in proc.stderr
    assert "yunohost app install" not in proc.stderr
    assert tunnel_token not in proc.stdout + proc.stderr
    saved = json.loads((etc / "cloudflared" / "handoff.json").read_text(encoding="utf-8"))
    assert "jellyfin.smith.tinyweb.win" in [row["name"] for row in saved["dns"]]
    assert not (dest / "tunnel.env").exists()


def test_tinyweb_env_off_removes_the_host(tmp_path: Path) -> None:
    provider = Publishing()
    base, server = _plane(tmp_path, provider)
    etc = tmp_path / "etc"
    dest = tmp_path / "dest"
    try:
        _code, _claim, tunnel_token = _prepare(base, etc, jellyfin=True)
        (etc / "tinyweb.env").write_text("TWS_JELLYFIN=0\n", encoding="utf-8")
        env = os.environ.copy()
        env.pop("TWS_JELLYFIN", None)
        env.update(
            {
                "TWS_ETC_DIR": str(etc),
                "TWS_CONTROL_PLANE_URL": base,
                "TWS_SETUP_CLOUDFLARED_DEST": str(dest),
                "TW_STACK_SKIP_LOCAL_ENV": "1",
            }
        )
        proc = subprocess.run(
            ["bash", str(INSTALL), "smith.tinyweb.win"],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
    finally:
        _stop(server)
    assert proc.returncode == 0, proc.stderr
    assert "Jellyfin install skipped" in proc.stderr
    assert "yunohost app install" not in proc.stderr
    assert tunnel_token not in proc.stdout + proc.stderr
    saved = json.loads((etc / "cloudflared" / "handoff.json").read_text(encoding="utf-8"))
    assert saved["published"] is True
    assert "jellyfin.smith.tinyweb.win" not in [row["name"] for row in saved["dns"]]


def test_script_help_does_not_require_a_token() -> None:
    proc = subprocess.run(["bash", str(HOSTS), "--help"], text=True, capture_output=True, check=False)
    assert proc.returncode == 0
    assert "claim token" in proc.stdout
    assert "setup code" in proc.stdout
    assert "published" in proc.stdout
