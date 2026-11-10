"""Box-side cloudflared hook. Missing credentials must not look like a live name."""

from __future__ import annotations

import json
import os
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APPLY = ROOT / "scripts" / "cloudflared-apply.sh"
INSTALL = ROOT / "scripts" / "cloudflared-install.sh"
TOKEN = "example-tunnel-token-value"


def _run(script: Path, *args: str, **kwargs) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(script), *args],
        text=True,
        capture_output=True,
        check=False,
        cwd=ROOT,
        env={**os.environ, "PATH": os.environ.get("PATH", "/usr/bin:/bin")},
        **kwargs,
    )


def _handoff(path: Path, *, published: bool | None, nested: bool = False) -> None:
    tunnel = {
        "tunnel_id": "tunnel1234",
        "token": TOKEN,
        "account_tag": "account",
    }
    if nested:
        body: dict = {"tunnel": tunnel, "slug": "smith", "domain": "smith.tinyweb.win"}
    else:
        body = dict(tunnel)
    if published is not None:
        body["published"] = published
    path.write_text(json.dumps(body), encoding="utf-8")


def test_apply_refuses_missing_credentials(tmp_path: Path) -> None:
    missing = tmp_path / "no-such.json"
    proc = _run(APPLY, "--credentials", str(missing), "--dry-run")
    assert proc.returncode != 0
    assert "Refusing to publish" in proc.stderr
    assert "service_started=yes" not in proc.stdout
    assert "smith.tinyweb.win" not in proc.stdout
    assert TOKEN not in proc.stdout
    assert TOKEN not in proc.stderr


def test_apply_refuses_unpublished_handoff(tmp_path: Path) -> None:
    path = tmp_path / "handoff.json"
    _handoff(path, published=False)
    proc = _run(APPLY, "--credentials", str(path), "--dry-run")
    assert proc.returncode != 0
    assert "published=false" in proc.stderr
    assert "service_started=no" not in proc.stdout
    assert not (tmp_path / "tunnel.env").exists()


def test_apply_refuses_when_published_is_omitted(tmp_path: Path) -> None:
    path = tmp_path / "handoff.json"
    _handoff(path, published=None)
    proc = _run(APPLY, "--credentials", str(path), "--dest-dir", str(tmp_path / "out"))
    assert proc.returncode != 0
    assert "published=true" in proc.stderr
    assert not (tmp_path / "out").exists()
    assert TOKEN not in proc.stdout
    assert TOKEN not in proc.stderr


def test_apply_dry_run_does_not_start_or_write(tmp_path: Path) -> None:
    path = tmp_path / "handoff.json"
    _handoff(path, published=True, nested=True)
    proc = _run(APPLY, "--credentials", str(path), "--dry-run", "--dest-dir", str(tmp_path / "out"))
    assert proc.returncode == 0, proc.stderr
    assert "tunnel_id=tunnel1234" in proc.stdout
    assert "service_started=no" in proc.stdout
    assert "dns_changed=no" in proc.stdout
    assert TOKEN not in proc.stdout
    assert TOKEN not in proc.stderr
    assert not (tmp_path / "out").exists()


def test_apply_stages_a_unit_without_the_token_on_the_command_line(tmp_path: Path) -> None:
    path = tmp_path / "handoff.json"
    dest = tmp_path / "staged"
    _handoff(path, published=True)
    proc = _run(APPLY, "--credentials", str(path), "--dest-dir", str(dest))
    assert proc.returncode == 0, proc.stderr
    assert "service_started=no" in proc.stdout
    assert "dns_changed=no" in proc.stdout
    assert TOKEN not in proc.stdout
    env_file = dest / "tunnel.env"
    unit = dest / "tinyweb-cloudflared.service"
    assert stat.S_IMODE(env_file.stat().st_mode) == 0o600
    assert stat.S_IMODE(dest.stat().st_mode) == 0o700
    assert f"TUNNEL_TOKEN={TOKEN}" in env_file.read_text(encoding="utf-8")
    unit_text = unit.read_text(encoding="utf-8")
    assert TOKEN not in unit_text
    assert "EnvironmentFile=" in unit_text
    assert "cloudflared tunnel --no-autoupdate run" in unit_text or "tunnel --no-autoupdate run" in unit_text
    assert "smith.tinyweb.win" not in unit_text


def test_install_dry_run_does_not_claim_a_hostname() -> None:
    proc = _run(INSTALL, "--dry-run")
    assert proc.returncode == 0, proc.stderr
    combined = proc.stdout + proc.stderr
    assert "tunnel" in combined.lower()
    assert "not publishing a hostname" in combined.lower() or "not starting a tunnel" in combined.lower()
    assert TOKEN not in combined
