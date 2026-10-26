"""Tests for <family>.tinyweb.win installer and DDNS helpers."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DDNS = ROOT / "scripts" / "vm" / "tinyweb-subdomain-ddns.sh"
INSTALL_ON_BOX = ROOT / "scripts" / "install-on-box.sh"


def test_ddns_dry_run_prints_family_domain() -> None:
    proc = subprocess.run(
        ["bash", str(DDNS), "--family", "smith", "--dry-run"],
        cwd=ROOT,
        env={k: v for k, v in os.environ.items() if k != "DRY_RUN"},
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    out = proc.stdout
    assert "smith.tinyweb.win" in out
    assert "*.smith.tinyweb.win" in out


def test_install_on_box_positional_family_dry_run() -> None:
    proc = subprocess.run(
        ["bash", str(INSTALL_ON_BOX), "smith", "--dry-run"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    assert "TWS_DOMAIN=smith.tinyweb.win" in proc.stderr
