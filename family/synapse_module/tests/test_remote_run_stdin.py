"""remote-run.sh forwards piped stdin to the VM script (no nested heredoc)."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
REMOTE_RUN = ROOT / "scripts" / "vm" / "remote-run.sh"


def test_remote_run_syncs_nodes_conf_when_present() -> None:
    text = REMOTE_RUN.read_text(encoding="utf-8")
    assert "config/nodes.conf" in text
    assert "tinywebstack-staging/config/nodes.conf" in text


def test_remote_run_dry_run_exits_zero() -> None:
    env = os.environ.copy()
    env["DRY_RUN"] = "1"
    env["TW_NODES_CONF"] = str(ROOT / "config" / "nodes.conf.example")
    proc = subprocess.run(
        ["bash", str(REMOTE_RUN), "127.0.0.1", "true"],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(ROOT),
        timeout=30,
    )
    assert proc.returncode == 0
    assert "remote-run-on-node.sh" in proc.stderr + proc.stdout


def test_remote_run_forwards_stdin_to_remote_script(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    stdin_capture = tmp_path / "stdin-capture.txt"

    ssh_stub = fake_bin / "ssh"
    ssh_stub.write_text(
        f"""#!/usr/bin/env bash
set -euo pipefail
stdin_forward=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) stdin_forward=0; shift; continue ;;
    -o|-i) shift 2; continue ;;
    -*) shift; continue ;;
    *) break ;;
  esac
done
shift
if [[ "$stdin_forward" == 1 ]]; then
  cat > "{stdin_capture}"
fi
"""
    )
    ssh_stub.chmod(ssh_stub.stat().st_mode | stat.S_IEXEC)

    rsync_stub = fake_bin / "rsync"
    rsync_stub.write_text("#!/bin/sh\nexit 0\n")
    rsync_stub.chmod(rsync_stub.stat().st_mode | stat.S_IEXEC)

    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env.get('PATH', '')}"
    env["TW_NODES_CONF"] = str(ROOT / "config" / "nodes.conf.example")
    env.pop("DRY_RUN", None)

    secret = "stdin-secret-payload"
    proc = subprocess.run(
        ["bash", str(REMOTE_RUN), "192.168.122.47", "tws-store-mobilizon-admin-password.sh"],
        input=secret,
        capture_output=True,
        text=True,
        env=env,
        cwd=str(ROOT),
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    assert stdin_capture.read_text(encoding="utf-8") == secret
