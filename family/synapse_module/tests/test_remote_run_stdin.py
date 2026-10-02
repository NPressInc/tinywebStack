"""remote-run.sh forwards piped stdin to the VM script (no nested heredoc)."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
REMOTE_RUN = ROOT / "scripts" / "vm" / "remote-run.sh"
REMOTE_ON_NODE = "tinywebstack-staging/vm/remote-run-on-node.sh"


def _write_ssh_stub(
    fake_bin: Path,
    log_file: Path,
    *,
    fail_on_node_script: bool = False,
) -> None:
    stdin_capture = fake_bin.parent / "stdin-capture.txt"
    ssh_stub = fake_bin / "ssh"
    fail_flag = "1" if fail_on_node_script else "0"
    ssh_stub.write_text(
        f"""#!/usr/bin/env bash
set -euo pipefail
{{
  printf 'INV:'
  printf ' %q' "$@"
  printf '\\n'
}} >> "{log_file}"
stdin_forward=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) stdin_forward=0; shift; continue ;;
    -o|-i) shift 2; continue ;;
    -*) shift; continue ;;
    *) break ;;
  esac
done
target="$1"
shift
if [[ "{fail_flag}" == "1" ]]; then
  for arg in "$@"; do
    if [[ "$arg" == *remote-run-on-node.sh* ]]; then
      exit 127
    fi
  done
fi
if [[ "$stdin_forward" == 1 ]]; then
  cat > "{stdin_capture}" 2>/dev/null || true
fi
exit 0
"""
    )
    ssh_stub.chmod(ssh_stub.stat().st_mode | stat.S_IEXEC)

    rsync_stub = fake_bin / "rsync"
    rsync_stub.write_text("#!/bin/sh\nexit 0\n")
    rsync_stub.chmod(rsync_stub.stat().st_mode | stat.S_IEXEC)

    keygen_stub = fake_bin / "ssh-keygen"
    keygen_stub.write_text(
        """#!/bin/sh
if [ "$1" = "-F" ]; then
  exit 0
fi
exit 0
"""
    )
    keygen_stub.chmod(keygen_stub.stat().st_mode | stat.S_IEXEC)

    keyscan_stub = fake_bin / "ssh-keyscan"
    keyscan_stub.write_text("#!/bin/sh\nexit 0\n")
    keyscan_stub.chmod(keyscan_stub.stat().st_mode | stat.S_IEXEC)


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
    _write_ssh_stub(fake_bin, tmp_path / "ssh.log")

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
    assert (fake_bin.parent / "stdin-capture.txt").read_text(encoding="utf-8") == secret


def test_remote_run_ssh_argv_uses_remote_on_node_path(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    ssh_log = tmp_path / "ssh.log"
    _write_ssh_stub(fake_bin, ssh_log)

    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env.get('PATH', '')}"
    env["TW_NODES_CONF"] = str(ROOT / "config" / "nodes.conf.example")
    env.pop("DRY_RUN", None)
    local_home = env.get("HOME", "")

    proc = subprocess.run(
        ["bash", str(REMOTE_RUN), "10.255.0.48", "true"],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(ROOT),
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    log_text = ssh_log.read_text(encoding="utf-8")
    node_invocations = [
        line for line in log_text.splitlines() if "remote-run-on-node.sh" in line
    ]
    assert node_invocations, log_text
    joined = "\n".join(node_invocations)
    assert REMOTE_ON_NODE in joined
    if local_home:
        assert f"{local_home}/tinywebstack-staging" not in joined


def test_remote_run_failed_ssh_cleans_remote_env_preserves_exit(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    ssh_log = tmp_path / "ssh.log"
    _write_ssh_stub(fake_bin, ssh_log, fail_on_node_script=True)

    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:{env.get('PATH', '')}"
    env["TW_NODES_CONF"] = str(ROOT / "config" / "nodes.conf.example")
    env.pop("DRY_RUN", None)

    proc = subprocess.run(
        ["bash", str(REMOTE_RUN), "10.255.0.49", "true"],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(ROOT),
        timeout=30,
    )
    assert proc.returncode == 127, proc.stderr + proc.stdout
    log_text = ssh_log.read_text(encoding="utf-8")
    assert "tinywebstack-staging/remote.env" in log_text
    assert "/opt/tinywebstack/remote.env" in log_text
