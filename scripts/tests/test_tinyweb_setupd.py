"""LAN setup service: discovery packets, local API, and installer handoff."""

from __future__ import annotations

import json
import os
import socket
import stat
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
import sys

sys.path.insert(0, str(ROOT / "scripts" / "setup"))

from tinyweb_setup.mdns import beacon_packet, build_announcement, packet_is_query_for_us  # noqa: E402
from tinyweb_setup.service import (  # noqa: E402
    SetupBindError,
    SetupConfig,
    SetupHTTPServer,
    SetupStore,
    bind_addresses,
    extract_setup_code,
    main,
)


SETUP_CODE = "box-setup-code-22"
PASSWORD = "correct-horse-battery"


def _config(tmp_path: Path, **overrides: object) -> SetupConfig:
    etc = tmp_path / "etc"
    etc.mkdir(exist_ok=True)
    code = etc / "setup-code"
    if not code.exists():
        code.write_text(SETUP_CODE + "\n", encoding="utf-8")
        code.chmod(0o600)
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
        "post_limit": 10,
        "post_window_s": 600,
    }
    values.update(overrides)
    return SetupConfig(**values)  # type: ignore[arg-type]


def _installer(tmp_path: Path, *, exit_code: int = 0) -> Path:
    script = tmp_path / "install.sh"
    script.write_text(
        f"""#!/bin/bash
printf '%s\\n' "$*" > "$TWS_TEST_ARGV"
env > "$TWS_TEST_ENV"
echo "=== Step 0: preflight ==="
echo "=== Step 6: family-init ==="
exit {exit_code}
""",
        encoding="utf-8",
    )
    script.chmod(0o755)
    return script


def _start(store: SetupStore) -> tuple[SetupHTTPServer, str]:
    httpd = SetupHTTPServer(("127.0.0.1", 0), store)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    port = httpd.server_address[1]
    return httpd, f"http://127.0.0.1:{port}"


def _request(url: str, payload: dict[str, str] | None = None) -> tuple[int, dict]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="GET" if data is None else "POST")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            return resp.status, body
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        return exc.code, json.loads(raw)


def _wait_phase(base: str, phase: str) -> dict:
    last: dict = {}
    for _ in range(50):
        status, last = _request(f"{base}/v1/setup/status")
        assert status == 200
        if last["phase"] == phase:
            return last
        time.sleep(0.05)
    raise AssertionError(f"phase stayed {last.get('phase')}")


def test_refuses_public_bind() -> None:
    with pytest.raises(SetupBindError):
        bind_addresses(["8.8.8.8"], allow_loopback=False)


def test_loopback_peer_requires_explicit_bind() -> None:
    assert bind_addresses(["127.0.0.1"], allow_loopback=True) == ["127.0.0.1"]
    with pytest.raises(SetupBindError):
        bind_addresses(["127.0.0.1"], allow_loopback=False)


def test_setup_code_accepts_fragment_and_rejects_query() -> None:
    assert extract_setup_code(SETUP_CODE) == SETUP_CODE
    assert extract_setup_code(f"https://tinyweb.win/setup#code={SETUP_CODE}") == SETUP_CODE
    assert extract_setup_code(f"tinyweb://setup#code={SETUP_CODE}") == SETUP_CODE
    with pytest.raises(Exception):
        extract_setup_code(f"https://tinyweb.win/setup?code={SETUP_CODE}")


def test_announcement_has_service_and_no_secrets() -> None:
    packet = build_announcement(4734, "192.168.1.50")
    assert packet_is_query_for_us(packet)
    assert b"\x0e_tinyweb-setup" in packet
    assert socket.inet_aton("192.168.1.50") in packet
    assert SETUP_CODE.encode() not in packet
    assert PASSWORD.encode() not in packet
    beacon = beacon_packet(4734)
    assert b"tinyweb-setup" in beacon
    assert SETUP_CODE.encode() not in beacon
    assert PASSWORD.encode() not in beacon


def test_status_waiting_and_password_round_trip(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    argv = tmp_path / "argv"
    envf = tmp_path / "env"
    monkeypatch.setenv("TWS_TEST_ARGV", str(argv))
    monkeypatch.setenv("TWS_TEST_ENV", str(envf))
    script = _installer(tmp_path)
    cfg = _config(
        tmp_path,
        install_cmd=["bash", str(script)],
        gate_override=False,
    )
    store = SetupStore(cfg)
    httpd, base = _start(store)
    try:
        status, body = _request(f"{base}/v1/setup/status")
        assert status == 200
        assert body["phase"] == "waiting"
        assert body["code_required"] is True
        assert PASSWORD not in json.dumps(body)
        assert SETUP_CODE not in json.dumps(body)

        status, body = _request(
            f"{base}/v1/setup",
            {
                "code": f"https://tinyweb.win/setup#code={SETUP_CODE}",
                "family_name": "Floyd",
                "parent_name": "William Floyd",
                "password": PASSWORD,
            },
        )
        assert status == 200, body
        assert body["family_slug"] == "floyd"
        assert body["parent_username"] == "william"
        assert body["domain"] == "floyd.tinyweb.win"
        assert PASSWORD not in json.dumps(body)
        assert SETUP_CODE not in json.dumps(body)

        done = _wait_phase(base, "blocked")
        labels = {step["id"]: step for step in done["steps"]}
        assert labels["install"]["state"] == "done"
        assert labels["certificate"]["state"] == "blocked"
        assert "Let's Encrypt" in labels["certificate"]["detail"]
        assert labels["tunnel"]["state"] == "blocked"
        assert labels["ready"]["state"] != "done"
        assert done["enroll_origin"] is None
        assert done["phase"] == "blocked"

        env_text = (cfg.env_file).read_text(encoding="utf-8")
        assert "TWS_DOMAIN=floyd" in env_text
        assert "TWS_MODE=production" in env_text
        assert "TWS_TLS_SINGLE_SAN_CERT=1" in env_text
        assert "TWS_TLS_EDGE_CERT=1" in env_text
        assert "TWS_JELLYFIN=0" in env_text
        assert "TWS_FAMILY_USERS=william" in env_text
        assert "TWS_FAMILY_PARENTS=william" in env_text
        assert "TWS_FAMILY_KIDS=" in env_text
        assert "TWS_FAMILY_OWNER_FULLNAME=William Floyd" in env_text
        assert PASSWORD not in env_text
        assert SETUP_CODE not in env_text

        secret = cfg.secrets_env
        assert stat.S_IMODE(secret.stat().st_mode) == 0o600
        sourced = subprocess.run(
            ["bash", "-c", f'source "{secret}"; printf %s "$WILLIAM_PASSWORD"'],
            check=False,
            capture_output=True,
            text=True,
        )
        assert sourced.stdout == PASSWORD
        assert PASSWORD not in (argv.read_text(encoding="utf-8") + envf.read_text(encoding="utf-8"))
        assert PASSWORD not in cfg.state_file.read_text(encoding="utf-8")
        assert SETUP_CODE not in cfg.state_file.read_text(encoding="utf-8")
        assert PASSWORD not in "\n".join(store.logs)
        assert SETUP_CODE not in "\n".join(store.logs)
        assert cfg.code_file.is_file()

        again, again_body = _request(
            f"{base}/v1/setup",
            {
                "code": SETUP_CODE,
                "family_name": "Floyd",
                "parent_name": "William",
                "password": PASSWORD,
            },
        )
        assert again == 409
        assert PASSWORD not in json.dumps(again_body)
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_wrong_code_and_failed_install_keeps_code(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TWS_TEST_ARGV", str(tmp_path / "argv"))
    monkeypatch.setenv("TWS_TEST_ENV", str(tmp_path / "env"))
    script = _installer(tmp_path, exit_code=1)
    cfg = _config(tmp_path, install_cmd=["bash", str(script)], post_limit=3)
    store = SetupStore(cfg)
    httpd, base = _start(store)
    try:
        status, body = _request(
            f"{base}/v1/setup",
            {
                "code": "not-the-code",
                "family_name": "Floyd",
                "parent_name": "William",
                "password": PASSWORD,
            },
        )
        assert status == 401
        assert "not-the-code" not in json.dumps(body)
        assert cfg.code_file.read_text(encoding="utf-8").strip() == SETUP_CODE
        assert not cfg.env_file.exists()

        status, _body = _request(
            f"{base}/v1/setup",
            {
                "code": f"tinyweb://setup#code={SETUP_CODE}",
                "family_name": "Floyd",
                "parent_name": "William",
                "password": PASSWORD,
            },
        )
        assert status == 200
        failed = _wait_phase(base, "failed")
        assert "same setup code" in (failed["error"] or "")
        assert cfg.code_file.is_file()
        assert not cfg.marker_file.exists()
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_ready_only_when_gates_are_ready(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TWS_TEST_ARGV", str(tmp_path / "argv"))
    monkeypatch.setenv("TWS_TEST_ENV", str(tmp_path / "env"))
    script = _installer(tmp_path)
    cfg = _config(
        tmp_path,
        install_cmd=["bash", str(script)],
        gate_override=True,
        gate_control_plane="ready",
        gate_tunnel="ready",
    )
    store = SetupStore(cfg)
    httpd, base = _start(store)
    try:
        status, _body = _request(
            f"{base}/v1/setup",
            {
                "code": SETUP_CODE,
                "family_name": "Floyd",
                "parent_name": "William",
                "password": PASSWORD,
            },
        )
        assert status == 200
        ready = _wait_phase(base, "ready")
        assert ready["enroll_origin"] == "https://floyd.tinyweb.win"
        assert ready["provisioned"] is True
        assert all(step["state"] == "done" for step in ready["steps"])
        assert not cfg.code_file.exists()
        consumed = cfg.consumed_file.read_text(encoding="utf-8")
        assert "consumed" in consumed
        assert SETUP_CODE not in consumed
        assert PASSWORD not in consumed
        assert cfg.marker_file.is_file()
        status, body = _request(
            f"{base}/v1/setup",
            {
                "code": SETUP_CODE,
                "family_name": "Floyd",
                "parent_name": "William",
                "password": PASSWORD,
            },
        )
        assert status == 409
        assert PASSWORD not in json.dumps(body)
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_main_does_not_listen_when_already_set_up(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    etc = tmp_path / "etc"
    etc.mkdir()
    (etc / "unboxing-complete").write_text("ready\n", encoding="utf-8")
    monkeypatch.setenv("TWS_ETC_DIR", str(etc))
    monkeypatch.setenv("TWS_SETUP_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("TWS_YUNOHOST_INSTALLED_FILE", str(tmp_path / "missing-yunohost"))
    monkeypatch.setenv("TWS_SETUP_ANNOUNCE", "0")
    monkeypatch.setenv("TWS_SETUP_BIND", "127.0.0.1")
    assert main() == 0


def test_main_skips_operator_yunohost(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    etc = tmp_path / "etc"
    etc.mkdir()
    marker = tmp_path / "installed"
    marker.write_text("12\n", encoding="utf-8")
    monkeypatch.setenv("TWS_ETC_DIR", str(etc))
    monkeypatch.setenv("TWS_SETUP_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("TWS_YUNOHOST_INSTALLED_FILE", str(marker))
    monkeypatch.setenv("TWS_SETUP_ANNOUNCE", "0")
    monkeypatch.setenv("TWS_SETUP_BIND", "127.0.0.1")
    assert main() == 0


def test_main_refuses_public_bind(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    etc = tmp_path / "etc"
    etc.mkdir()
    monkeypatch.setenv("TWS_ETC_DIR", str(etc))
    monkeypatch.setenv("TWS_SETUP_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("TWS_YUNOHOST_INSTALLED_FILE", str(tmp_path / "missing"))
    monkeypatch.setenv("TWS_SETUP_ANNOUNCE", "0")
    monkeypatch.setenv("TWS_SETUP_BIND", "8.8.8.8")
    assert main() == 1


def test_edge_cert_skips_on_box_lets_encrypt() -> None:
    script = f"""
set -euo pipefail
export TWS_INSTALL_NO_MAIN=1
source "{ROOT}/scripts/install-tinyweb.sh"
export TWS_MODE=production
export TWS_DOMAIN=floyd.tinyweb.win
export TWS_TLS_SINGLE_SAN_CERT=1
export TWS_TLS_EDGE_CERT=1
export DRY_RUN=1
step_tls
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    assert "Skipping on-box Let's Encrypt" in proc.stderr + proc.stdout
    assert "Provisioning single SAN" not in proc.stderr + proc.stdout


def test_local_env_quotes_owner_fullname(tmp_path: Path) -> None:
    dest = tmp_path / "stack"
    dest.mkdir()
    script = f"""
set -euo pipefail
export TWS_INSTALL_NO_MAIN=1
source "{ROOT}/scripts/install-tinyweb.sh"
export TWS_INSTALL_ROOT="{dest}"
export LOCATION_APP=owntracks EVENTS_APP=mobilizon YUNOHOST_ADMIN_USER=twsowner
export TWS_LAB_TLS_INSECURE=0
export TWS_FAMILY_OWNER=william
export TWS_FAMILY_OWNER_FULLNAME="William Floyd"
export TWS_FAMILY_USERS=william TWS_FAMILY_PARENTS=william TWS_FAMILY_KIDS=
write_stack_local_env
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        env={k: v for k, v in os.environ.items() if k != "DRY_RUN"},
    )
    assert proc.returncode == 0, proc.stderr
    sourced = subprocess.run(
        ["bash", "-c", f'source "{dest}/local.env"; printf %s "$TWS_FAMILY_OWNER_FULLNAME"'],
        check=False,
        capture_output=True,
        text=True,
    )
    assert sourced.stdout == "William Floyd"
