"""First boot calls the control plane. The fake provider must not look published."""

from __future__ import annotations

import json
import os
import socket
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "setup"))
sys.path.insert(0, str(ROOT / "controlplane"))

from tinyweb_controlplane.app import create_app  # noqa: E402
from tinyweb_controlplane.config import Settings  # noqa: E402
from tinyweb_controlplane.providers import FakeProvider, UnconfiguredProvider  # noqa: E402
from tinyweb_controlplane.store import Store  # noqa: E402
from tinyweb_setup.control_plane import (  # noqa: E402
    ControlPlaneClient,
    ControlPlaneError,
    evaluate_handoff,
)
from tinyweb_setup.service import SetupConfig, SetupHTTPServer, SetupStore  # noqa: E402

import uvicorn  # noqa: E402

PRE_SHIP = ROOT / "scripts" / "setup" / "pre-ship.py"
OPERATOR = "operator-test-token"


def _plane(tmp_path: Path, provider):
    settings = Settings(
        db_path=str(tmp_path / "cp.sqlite"),
        operator_token=OPERATOR,
        provider_name="fake",
        base_domain="tinyweb.win",
        public_origin="https://tinyweb.win",
    )
    store = Store(settings.db_path)
    app = create_app(settings, provider=provider, store=store)
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
    return f"http://127.0.0.1:{port}", server, store


def _stop(server: uvicorn.Server) -> None:
    server.should_exit = True


def _mint(base: str) -> dict:
    request = urllib.request.Request(
        base + "/v1/operator/units",
        data=b"",
        headers={"Authorization": f"Bearer {OPERATOR}"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.loads(response.read().decode("utf-8"))


def _config(tmp_path: Path, **overrides: object) -> SetupConfig:
    etc = tmp_path / "etc"
    etc.mkdir(exist_ok=True)
    code = etc / "setup-code"
    values: dict[str, object] = {
        "etc_dir": etc,
        "state_dir": tmp_path / "state",
        "code_file": code,
        "bind": ["127.0.0.1"],
        "allow_loopback": True,
        "port": 0,
        "announce": False,
        "install_cmd": None,
        "repo_root": ROOT,
        "base_domain": "tinyweb.win",
        "yunohost_marker": tmp_path / "no-yunohost",
        "gate_override": False,
        "gate_control_plane": None,
        "gate_tunnel": None,
    }
    values.update(overrides)
    return SetupConfig(**values)  # type: ignore[arg-type]


def _installer(tmp_path: Path) -> Path:
    script = tmp_path / "install.sh"
    script.write_text(
        """#!/bin/bash
echo "=== Step 0: preflight ==="
exit 0
""",
        encoding="utf-8",
    )
    script.chmod(0o755)
    return script


def _start(store: SetupStore) -> tuple[SetupHTTPServer, str]:
    httpd = SetupHTTPServer(("127.0.0.1", 0), store)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    port = httpd.server_address[1]
    return httpd, f"http://127.0.0.1:{port}"


def _request(url: str, payload: dict[str, str] | None = None) -> tuple[int, dict]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="GET" if data is None else "POST")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8"))


def _wait_phase(base: str, phase: str) -> dict:
    last: dict = {}
    for _ in range(80):
        status, last = _request(f"{base}/v1/setup/status")
        assert status == 200
        if last["phase"] == phase:
            return last
        time.sleep(0.05)
    raise AssertionError(f"phase stayed {last.get('phase')}")


def _write_code(cfg: SetupConfig, code: str) -> None:
    cfg.code_file.write_text(code + "\n", encoding="utf-8")
    cfg.code_file.chmod(0o600)


def test_evaluate_handoff_never_treats_the_fake_shape_as_ready() -> None:
    fake = {
        "published": False,
        "edge_certificate_ready": False,
        "certificate": {"ready": False},
        "dns": [{"name": "floyd.tinyweb.win", "proxied": True}],
    }
    decision = evaluate_handoff(fake, 0)
    assert decision.complete is False
    assert decision.name_ready is False
    assert decision.certificate_ready is False
    assert decision.tunnel_ready is False

    published = {
        "published": True,
        "edge_certificate_ready": True,
        "certificate": {"ready": True},
        "dns": [{"name": "floyd.tinyweb.win"}],
    }
    ready = evaluate_handoff(published, 0)
    assert ready.complete is True
    assert evaluate_handoff(published, 1).complete is False
    pending = dict(published)
    pending["edge_certificate_ready"] = False
    pending["certificate"] = {"ready": False}
    assert evaluate_handoff(pending, 0).reason == "certificate_pending"
    jelly = dict(published)
    jelly["dns"] = [{"name": "jellyfin.floyd.tinyweb.win", "proxied": True}]
    assert evaluate_handoff(jelly, 0).complete is True
    unpublished_jelly = dict(fake)
    unpublished_jelly["dns"] = [{"name": "jellyfin.floyd.tinyweb.win", "proxied": True}]
    assert evaluate_handoff(unpublished_jelly, 0).complete is False
    assert evaluate_handoff(unpublished_jelly, 0).reason == "unpublished"
    assert evaluate_handoff(None, 0).complete is False


def test_client_rejects_query_strings_and_cleartext_public_urls() -> None:
    with pytest.raises(ControlPlaneError):
        ControlPlaneClient("http://tinyweb.win")
    with pytest.raises(ControlPlaneError):
        ControlPlaneClient("https://tinyweb.win/setup?code=secret")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            self.server.seen.append(("GET", self.path))  # type: ignore[attr-defined]
            body = json.dumps(
                {"slug": "floyd", "available": True, "domain": "floyd.tinyweb.win", "reason": None}
            ).encode("utf-8")
            self._send(body)

        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length)
            self.server.seen.append(("POST", self.path, raw, self.headers.get("Authorization")))  # type: ignore[attr-defined]
            body = json.dumps({"status": "claimed", "claim_token": "claim-token-value-123456"}).encode()
            self._send(body)

        def _send(self, body: bytes) -> None:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt: str, *args: object) -> None:
            return

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    httpd.seen = []  # type: ignore[attr-defined]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        client = ControlPlaneClient(f"http://127.0.0.1:{httpd.server_address[1]}")
        client.check_slug("floyd")
        client.claim("box-setup-code-value", "floyd")
    finally:
        httpd.shutdown()
    assert httpd.seen[0] == ("GET", "/v1/slugs/floyd")
    method, path, raw, auth = httpd.seen[1]
    assert method == "POST"
    assert path == "/v1/setup/claim"
    assert "?" not in path
    assert json.loads(raw)["setup_code"] == "box-setup-code-value"
    assert auth is None


def test_setup_calls_the_fake_control_plane_and_stays_blocked(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("TWS_TEST_ARGV", str(tmp_path / "argv"))
    base, server, store = _plane(tmp_path, FakeProvider())
    minted = _mint(base)
    code = minted["setup_code"]
    try:
        script = _installer(tmp_path)
        dest = tmp_path / "cloudflared"
        cfg = _config(
            tmp_path,
            install_cmd=["bash", str(script)],
            control_plane_url=base,
            cloudflared_dest=dest,
            gate_override=True,
            gate_control_plane="ready",
            gate_tunnel="ready",
        )
        _write_code(cfg, code)
        setup = SetupStore(cfg)
        httpd, setup_base = _start(setup)
        try:
            status, body = _request(
                f"{setup_base}/v1/setup",
                {
                    "code": f"https://tinyweb.win/setup#code={code}",
                    "family_name": "Floyd",
                    "parent_name": "William",
                    "password": "correct-horse-battery",
                },
            )
            assert status == 200, body
            done = _wait_phase(setup_base, "blocked")
            assert done["enroll_origin"] is None
            assert done["provisioned"] is False
            labels = {step["id"]: step for step in done["steps"]}
            assert labels["name"]["state"] == "blocked"
            assert "has not published" in labels["name"]["detail"]
            assert labels["certificate"]["state"] == "blocked"
            assert "Let's Encrypt" in labels["certificate"]["detail"]
            assert labels["tunnel"]["state"] == "blocked"
            assert labels["ready"]["state"] != "done"
            handoff = json.loads(cfg.handoff_file.read_text(encoding="utf-8"))
            assert handoff["published"] is False
            assert handoff["edge_certificate_ready"] is False
            assert not any(str(row.get("name", "")).startswith("jellyfin.") for row in handoff["dns"])
            assert not (dest / "tunnel.env").exists()
            assert cfg.code_file.is_file()
            assert not cfg.marker_file.exists()
            claim_token = cfg.claim_token_file.read_text(encoding="utf-8").strip()
            tunnel_token = handoff["tunnel"]["token"]
            blob = json.dumps(done) + "\n" + "\n".join(setup.logs) + "\n" + cfg.state_file.read_text()
            assert code not in blob
            assert "correct-horse-battery" not in blob
            assert claim_token not in blob
            assert tunnel_token not in blob
            assert "cloudflared-apply exited" in "\n".join(setup.logs)
            row = store._conn.execute("SELECT setup_completed_at FROM units").fetchone()
            assert row["setup_completed_at"] is None
            slug = store.slug_row("floyd")
            assert slug is not None
        finally:
            httpd.shutdown()
            httpd.server_close()
    finally:
        _stop(server)


def test_enabled_jellyfin_is_on_the_handoff_and_setup_stays_blocked(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("TWS_JELLYFIN", "1")
    base, server, _store = _plane(tmp_path, FakeProvider())
    minted = _mint(base)
    try:
        cfg = _config(
            tmp_path,
            install_cmd=["bash", str(_installer(tmp_path))],
            control_plane_url=base,
            cloudflared_dest=tmp_path / "cloudflared",
        )
        _write_code(cfg, minted["setup_code"])
        setup = SetupStore(cfg)
        httpd, setup_base = _start(setup)
        try:
            status, body = _request(
                f"{setup_base}/v1/setup",
                {
                    "code": minted["setup_code"],
                    "family_name": "Floyd",
                    "parent_name": "William",
                    "password": "correct-horse-battery",
                },
            )
            assert status == 200, body
            done = _wait_phase(setup_base, "blocked")
            assert done["enroll_origin"] is None
            assert "Jellyfin" not in (done["error"] or "")
            handoff = json.loads(cfg.handoff_file.read_text(encoding="utf-8"))
            assert handoff["published"] is False
            names = [row["name"] for row in handoff["dns"]]
            assert "jellyfin.floyd.tinyweb.win" in names
            row = next(item for item in handoff["dns"] if item["name"] == "jellyfin.floyd.tinyweb.win")
            assert row["proxied"] is True
            assert row["applied"] is False
            assert handoff["excluded_from_proxy"] == []
            assert "immich" not in json.dumps(handoff)
            assert "TWS_JELLYFIN=1" in cfg.env_file.read_text(encoding="utf-8")
            assert not (tmp_path / "cloudflared" / "tunnel.env").exists()
            assert "cloudflared-apply exited" in "\n".join(setup.logs)
            assert cfg.code_file.is_file()
        finally:
            httpd.shutdown()
            httpd.server_close()
    finally:
        _stop(server)


def test_missing_cloudflare_credentials_stay_blocked(tmp_path: Path) -> None:
    provider = UnconfiguredProvider(["CF_API_TOKEN", "CF_ACCOUNT_ID", "CF_ZONE_ID"])
    base, server, _store = _plane(tmp_path, provider)
    minted = _mint(base)
    code = minted["setup_code"]
    try:
        cfg = _config(
            tmp_path,
            install_cmd=["bash", str(_installer(tmp_path))],
            control_plane_url=base,
            cloudflared_dest=tmp_path / "cloudflared",
        )
        _write_code(cfg, code)
        setup = SetupStore(cfg)
        httpd, setup_base = _start(setup)
        try:
            status, _body = _request(
                f"{setup_base}/v1/setup",
                {
                    "code": code,
                    "family_name": "Floyd",
                    "parent_name": "William",
                    "password": "correct-horse-battery",
                },
            )
            assert status == 200
            done = _wait_phase(setup_base, "blocked")
            assert "credentials" in (done["error"] or "")
            assert "No public name was published" in (done["error"] or "")
            assert not cfg.handoff_file.exists()
            assert cfg.code_file.is_file()
            assert not (tmp_path / "cloudflared" / "tunnel.env").exists()
        finally:
            httpd.shutdown()
            httpd.server_close()
    finally:
        _stop(server)


def test_slug_taken_does_not_start_install(tmp_path: Path) -> None:
    base, server, _store = _plane(tmp_path, FakeProvider())
    first = _mint(base)
    second = _mint(base)
    claim = urllib.request.Request(
        base + "/v1/setup/claim",
        data=json.dumps({"setup_code": first["setup_code"], "slug": "floyd"}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(claim, timeout=5) as response:
        assert response.status == 200
    try:
        cfg = _config(
            tmp_path,
            install_cmd=["bash", str(_installer(tmp_path))],
            control_plane_url=base,
        )
        _write_code(cfg, second["setup_code"])
        setup = SetupStore(cfg)
        httpd, setup_base = _start(setup)
        try:
            status, body = _request(
                f"{setup_base}/v1/setup",
                {
                    "code": second["setup_code"],
                    "family_name": "Floyd",
                    "parent_name": "William",
                    "password": "correct-horse-battery",
                },
            )
            assert status == 409
            assert "already in use" in (body["error"] or "")
            assert not cfg.env_file.exists()
            assert cfg.code_file.is_file()
            assert second["setup_code"] not in json.dumps(body)
        finally:
            httpd.shutdown()
            httpd.server_close()
    finally:
        _stop(server)


def _run_pre_ship(tmp_path: Path, *args: str, token: str | None = OPERATOR, url: str = "") -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.pop("TWS_CONTROL_PLANE_OPERATOR_TOKEN", None)
    if token is not None:
        env["TWS_CONTROL_PLANE_OPERATOR_TOKEN"] = token
    if url:
        env["TWS_CONTROL_PLANE_URL"] = url
    return subprocess.run(
        [sys.executable, str(PRE_SHIP), *args],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def test_pre_ship_dry_run_and_missing_token(tmp_path: Path) -> None:
    missing = _run_pre_ship(tmp_path, "--dry-run", token=None, url="http://127.0.0.1:9")
    assert missing.returncode == 2
    assert "TWS_CONTROL_PLANE_OPERATOR_TOKEN" in missing.stderr
    assert "http://" not in missing.stdout

    dry = _run_pre_ship(tmp_path, "--dry-run", url="http://127.0.0.1:9")
    assert dry.returncode == 0, dry.stderr
    assert "No setup code was written" in dry.stdout
    assert OPERATOR not in dry.stdout
    assert OPERATOR not in dry.stderr
    assert not (tmp_path / "setup-code").exists()

    down = _run_pre_ship(tmp_path, "--stage-dir", str(tmp_path / "stage"), url="http://127.0.0.1:9")
    assert down.returncode == 1
    assert "Could not reach the control plane" in down.stderr
    assert not (tmp_path / "stage" / "setup-code").exists()
    assert "setup#code=" not in down.stdout
    assert "setup#code=" not in down.stderr


def test_pre_ship_mints_with_the_fake_provider_and_does_not_log_the_code(tmp_path: Path) -> None:
    base, server, store = _plane(tmp_path, FakeProvider())
    stage = tmp_path / "stage"
    try:
        proc = _run_pre_ship(tmp_path, "--url", base, "--stage-dir", str(stage))
    finally:
        _stop(server)
    assert proc.returncode == 0, proc.stderr
    code_path = stage / "setup-code"
    qr_path = stage / "setup-qr.svg"
    assert stat.S_IMODE(code_path.stat().st_mode) == 0o600
    code = code_path.read_text(encoding="utf-8")
    assert code.endswith("\n")
    assert "\n" not in code.strip()
    token = code.strip()
    assert len(token) >= 22
    assert stat.S_IMODE(qr_path.stat().st_mode) == 0o600
    assert qr_path.read_text(encoding="utf-8").lstrip().startswith("<")
    assert f"https://tinyweb.win/setup#code={token}" in proc.stdout
    assert f"tinyweb://setup#code={token}" in proc.stdout
    assert "No family name or parent password was set" in proc.stdout
    assert "No Matrix recovery key was printed" in proc.stdout
    assert token not in proc.stderr
    assert OPERATOR not in proc.stdout
    assert OPERATOR not in proc.stderr
    unit = (stage / "systemd" / "tinyweb-setupd.service").read_text(encoding="utf-8")
    assert token not in unit
    assert f"Environment=TWS_CONTROL_PLANE_URL={base}" in unit
    assert (stage / "systemd" / "enabled").read_text(encoding="utf-8").strip() == "tinyweb-setupd.service"
    assert not (stage / "tinyweb.env").exists()
    assert store._conn.execute("SELECT COUNT(*) AS n FROM units").fetchone()["n"] == 1
    joined = " ".join(proc.args) if isinstance(proc.args, list) else str(proc.args)
    assert token not in joined
    assert OPERATOR not in joined


class _PublishingCert:
    """Publishes DNS, and reports the edge certificate ready after N reads."""

    publishes = True
    name = "cloudflare"

    def __init__(self, ready_after: int) -> None:
        self.ready_after = ready_after
        self.cert_calls = 0
        self.create_calls = 0

    def create_tunnel(self, spec):
        from tinyweb_controlplane.providers import IssuedTunnel

        self.create_calls += 1
        return IssuedTunnel(
            tunnel_id="00000000-0000-4000-8000-0000000000aa",
            account_tag="account",
            token="live-tunnel-token-example",
            credentials_file={"TunnelID": "00000000-0000-4000-8000-0000000000aa"},
            name=spec.name,
        )

    def delete_tunnel(self, tunnel_id: str) -> None:
        return None

    def upsert_cname(self, record) -> None:
        return None

    def delete_cname(self, name: str) -> None:
        return None

    def ensure_edge_certificate(self, request):
        from tinyweb_controlplane.providers import EdgeCertificate

        self.cert_calls += 1
        ready = self.cert_calls >= self.ready_after
        return EdgeCertificate(
            method=request.method,
            hosts=list(request.hosts),
            status="active" if ready else "pending_validation",
            pack_id="pack",
            ready=ready,
        )


def test_cert_wait_defaults_cover_minutes_and_env_still_overrides(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("TWS_SETUP_CERT_POLLS", raising=False)
    monkeypatch.delenv("TWS_SETUP_CERT_POLL_SECONDS", raising=False)
    monkeypatch.setenv("TWS_ETC_DIR", "/tmp/tinyweb-cert-defaults")
    monkeypatch.setenv("TWS_SETUP_BIND", "127.0.0.1")
    monkeypatch.setenv("TWS_SETUP_ANNOUNCE", "0")
    cfg = SetupConfig.from_env()
    assert cfg.cert_polls == 24
    assert cfg.cert_poll_seconds == 10
    assert 180 <= cfg.cert_polls * cfg.cert_poll_seconds <= 300
    monkeypatch.setenv("TWS_SETUP_CERT_POLLS", "2")
    monkeypatch.setenv("TWS_SETUP_CERT_POLL_SECONDS", "0.01")
    overridden = SetupConfig.from_env()
    assert overridden.cert_polls == 2
    assert overridden.cert_poll_seconds == 0.01


def _patch_cert_sleep(monkeypatch: pytest.MonkeyPatch, sleeps: list[float], seen: list[dict], store_box: dict):
    def fake_sleep(seconds: float) -> None:
        sleeps.append(seconds)
        seen.append(store_box["store"].public_status())

    monkeypatch.setattr("tinyweb_setup.service._cert_wait_sleep", fake_sleep)


def test_certificate_wait_is_visible_and_ready_only_when_the_cert_is_ready(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    provider = _PublishingCert(ready_after=2)
    base, server, cp_store = _plane(tmp_path, provider)
    minted = _mint(base)
    code = minted["setup_code"]
    sleeps: list[float] = []
    seen: list[dict] = []
    store_box: dict = {}
    _patch_cert_sleep(monkeypatch, sleeps, seen, store_box)
    try:
        cfg = _config(
            tmp_path,
            install_cmd=["bash", str(_installer(tmp_path))],
            control_plane_url=base,
            cloudflared_dest=tmp_path / "cloudflared",
            cert_polls=4,
            cert_poll_seconds=90,
        )
        _write_code(cfg, code)
        setup = SetupStore(cfg)
        store_box["store"] = setup
        httpd, setup_base = _start(setup)
        try:
            status, body = _request(
                f"{setup_base}/v1/setup",
                {
                    "code": code,
                    "family_name": "Floyd",
                    "parent_name": "William",
                    "password": "correct-horse-battery",
                },
            )
            assert status == 200, body
            ready = _wait_phase(setup_base, "ready")
        finally:
            httpd.shutdown()
            httpd.server_close()
    finally:
        _stop(server)
    assert sleeps == [90]
    assert seen, "certificate wait did not publish a status"
    waiting = seen[0]
    labels = {step["id"]: step for step in waiting["steps"]}
    assert waiting["phase"] == "installing"
    assert waiting["provisioned"] is False
    assert waiting["enroll_origin"] is None
    assert labels["certificate"]["state"] == "current"
    assert labels["certificate"]["detail"] == "Still setting up your secure connection."
    assert labels["install"]["state"] == "done"
    assert labels["ready"]["state"] != "done"
    assert "Try again" not in json.dumps(waiting)
    assert ready["phase"] == "ready"
    assert ready["provisioned"] is True
    assert ready["enroll_origin"] == "https://floyd.tinyweb.win"
    assert all(step["state"] == "done" for step in ready["steps"])
    assert not cfg.code_file.exists()
    assert cfg.marker_file.is_file()
    assert cp_store._conn.execute("SELECT setup_completed_at FROM units").fetchone()["setup_completed_at"]
    blob = json.dumps(waiting) + "\n" + json.dumps(ready) + "\n" + "\n".join(setup.logs)
    assert code not in blob
    assert "correct-horse-battery" not in blob
    assert "live-tunnel-token-example" not in blob
    claim_token = cfg.claim_token_file.read_text(encoding="utf-8").strip()
    assert claim_token not in blob


def test_certificate_timeout_keeps_the_setup_code_for_a_retry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    provider = _PublishingCert(ready_after=99)
    base, server, cp_store = _plane(tmp_path, provider)
    minted = _mint(base)
    code = minted["setup_code"]
    sleeps: list[float] = []
    seen: list[dict] = []
    store_box: dict = {}
    _patch_cert_sleep(monkeypatch, sleeps, seen, store_box)
    try:
        cfg = _config(
            tmp_path,
            install_cmd=["bash", str(_installer(tmp_path))],
            control_plane_url=base,
            cloudflared_dest=tmp_path / "cloudflared",
            cert_polls=2,
            cert_poll_seconds=30,
        )
        _write_code(cfg, code)
        setup = SetupStore(cfg)
        store_box["store"] = setup
        httpd, setup_base = _start(setup)
        try:
            status, body = _request(
                f"{setup_base}/v1/setup",
                {
                    "code": code,
                    "family_name": "Floyd",
                    "parent_name": "William",
                    "password": "correct-horse-battery",
                },
            )
            assert status == 200, body
            blocked = _wait_phase(setup_base, "blocked")
            assert sleeps == [30, 30]
            assert blocked["provisioned"] is False
            assert blocked["enroll_origin"] is None
            labels = {step["id"]: step for step in blocked["steps"]}
            assert labels["certificate"]["state"] == "blocked"
            assert "same setup code" in labels["certificate"]["detail"]
            assert labels["ready"]["state"] != "done"
            assert cfg.code_file.is_file()
            assert not cfg.marker_file.exists()
            assert cp_store._conn.execute("SELECT setup_completed_at FROM units").fetchone()["setup_completed_at"] is None
            for snapshot in seen:
                assert snapshot["phase"] == "installing"
                assert snapshot["provisioned"] is False
                cert = next(step for step in snapshot["steps"] if step["id"] == "certificate")
                assert cert["detail"] == "Still setting up your secure connection."
                assert code not in json.dumps(snapshot)

            provider.ready_after = 1
            retry, retried = _request(
                f"{setup_base}/v1/setup",
                {
                    "code": code,
                    "family_name": "Floyd",
                    "parent_name": "William",
                    "password": "correct-horse-battery",
                },
            )
            assert retry == 200, retried
            assert retried["phase"] == "ready"
            assert retried["enroll_origin"] == "https://floyd.tinyweb.win"
            assert not cfg.code_file.exists()
            assert cfg.marker_file.is_file()
            assert "live-tunnel-token-example" not in json.dumps(retried)
            assert code not in json.dumps(retried)
            assert cp_store._conn.execute("SELECT setup_completed_at FROM units").fetchone()["setup_completed_at"]
        finally:
            httpd.shutdown()
            httpd.server_close()
    finally:
        _stop(server)
