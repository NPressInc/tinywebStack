"""password-reset path in family-dashboard-privileged.sh (YunoHost 12 user_update)."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "vm" / "family-dashboard-privileged.sh"


def test_password_reset_uses_yunohost_user_update() -> None:
    text = SCRIPT.read_text(encoding="utf-8")
    assert "from yunohost.user import user_update" in text
    assert "user_update(user, change_password=password)" in text
    assert "trap cleanup_pw_file EXIT" in text


def test_password_reset_removes_temp_file_when_python_fails(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_py = fake_bin / "python3"
    fake_py.write_text("#!/bin/sh\nexit 1\n")
    fake_py.chmod(fake_py.stat().st_mode | stat.S_IEXEC)

    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env.get('PATH', '')}"
    env["TWS_PRIVILEGED_ALLOW_NON_ROOT"] = "1"
    env["TMPDIR"] = str(tmp_path)

    before = set(tmp_path.glob("tmp.*"))
    proc = subprocess.run(
        ["bash", str(SCRIPT), "password-reset", "parent1"],
        input="newpassword12\n",
        capture_output=True,
        text=True,
        env=env,
        cwd=str(ROOT),
    )
    assert proc.returncode != 0
    after = set(tmp_path.glob("tmp.*"))
    assert after == before, "password temp file must be removed on failure"
