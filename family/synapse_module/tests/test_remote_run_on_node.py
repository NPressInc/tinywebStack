"""Unit tests for scripts/vm/remote-run-on-node.sh (stubs only; no VM or real sudo)."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
REMOTE_RUN_ON_NODE = ROOT / "scripts" / "vm" / "remote-run-on-node.sh"


def _staging_layout(
    tmp_path: Path,
    *,
    script_body: str,
    script_name: str = "stub-target.sh",
) -> tuple[Path, Path, Path]:
    """Return (fake_bin, remote_root, staging) with HOME=tmp_path."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    remote_root = tmp_path / "opt" / "tinywebstack"
    staging = tmp_path / "tinywebstack-staging"
    vm_dir = staging / "vm"
    vm_dir.mkdir(parents=True)
    (staging / "defaults.env").write_text("TWS_FOO=bar\n", encoding="utf-8")
    (staging / "remote.env").write_text(
        "YUNOHOST_ADMIN_PASSWORD=secret-from-remote-env\n",
        encoding="utf-8",
    )
    (vm_dir / script_name).write_text(script_body, encoding="utf-8")
    (vm_dir / script_name).chmod(
        (vm_dir / script_name).stat().st_mode | stat.S_IEXEC
    )
    return fake_bin, remote_root, staging


def _write_sudo_stub(fake_bin: Path, log_path: Path) -> None:
    sudo_stub = fake_bin / "sudo"
    sudo_stub.write_text(
        f"""#!/usr/bin/env bash
set -euo pipefail
log="{log_path}"
printf '%s\\n' "$*" >> "$log"
case "$1" in
  mkdir)
    shift
    exec /bin/mkdir "$@"
    ;;
  rsync)
    shift
    src=""
    dst=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -a) shift ;;
        *) if [[ -z "$src" ]]; then src="$1"; else dst="$1"; fi; shift ;;
      esac
    done
    if [[ "$src" == */ ]]; then
      mkdir -p "$dst"
      cp -a "${{src}}." "$dst/"
    else
      mkdir -p "$(dirname "$dst")"
      cp -a "$src" "$dst"
    fi
    ;;
  install)
    shift
    mode=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -m) mode="$2"; shift 2 ;;
        *) break ;;
      esac
    done
    src="$1"
    dst="$2"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    if [[ -n "$mode" ]]; then
      chmod "$mode" "$dst"
    fi
    ;;
  rm)
    shift
    exec /bin/rm "$@"
    ;;
  bash)
    shift
    exec /bin/bash "$@"
    ;;
  *)
    echo "unexpected sudo: $*" >&2
    exit 1
    ;;
esac
""",
        encoding="utf-8",
    )
    sudo_stub.chmod(sudo_stub.stat().st_mode | stat.S_IEXEC)


def _run_on_node(
    tmp_path: Path,
    fake_bin: Path,
    remote_root: Path,
    script_name: str,
    *,
    stdin: str | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["HOME"] = str(tmp_path)
    env["PATH"] = f"{fake_bin}:{env.get('PATH', '')}"
    return subprocess.run(
        ["bash", str(REMOTE_RUN_ON_NODE), str(remote_root), script_name],
        input=stdin,
        capture_output=True,
        text=True,
        env=env,
        cwd=str(ROOT),
        timeout=30,
    )


def test_remote_run_on_node_removes_remote_env_after_success(tmp_path: Path) -> None:
    fake_bin, remote_root, staging = _staging_layout(
        tmp_path,
        script_body="#!/usr/bin/env bash\nexit 0\n",
    )
    log_path = tmp_path / "sudo.log"
    _write_sudo_stub(fake_bin, log_path)

    proc = _run_on_node(tmp_path, fake_bin, remote_root, "stub-target.sh")
    assert proc.returncode == 0, proc.stderr + proc.stdout
    assert not (staging / "remote.env").exists()
    assert not (remote_root / "remote.env").exists()
    sudo_log = log_path.read_text(encoding="utf-8")
    assert f"rm -f {remote_root}/remote.env" in sudo_log


def test_remote_run_on_node_removes_remote_env_after_failure(tmp_path: Path) -> None:
    fake_bin, remote_root, staging = _staging_layout(
        tmp_path,
        script_body="#!/usr/bin/env bash\nexit 42\n",
    )
    log_path = tmp_path / "sudo.log"
    _write_sudo_stub(fake_bin, log_path)

    proc = _run_on_node(tmp_path, fake_bin, remote_root, "stub-target.sh")
    assert proc.returncode == 42, proc.stderr + proc.stdout
    assert not (staging / "remote.env").exists()
    assert not (remote_root / "remote.env").exists()


def test_remote_run_on_node_forwards_stdin_to_vm_script_under_sudo(
    tmp_path: Path,
) -> None:
    capture = tmp_path / "stdin-capture.txt"
    fake_bin, remote_root, _staging = _staging_layout(
        tmp_path,
        script_body=f"""#!/usr/bin/env bash
cat > "{capture}"
""",
    )
    _write_sudo_stub(fake_bin, tmp_path / "sudo.log")

    secret = "stdin-under-sudo"
    proc = _run_on_node(
        tmp_path,
        fake_bin,
        remote_root,
        "stub-target.sh",
        stdin=secret,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    assert capture.read_text(encoding="utf-8") == secret


def test_remote_run_on_node_script_uses_sudo_bash_for_target() -> None:
    text = REMOTE_RUN_ON_NODE.read_text(encoding="utf-8")
    assert "sudo bash -c" in text
    assert "source \"${REMOTE_ROOT}/remote.env\"" in text
    assert "exec bash" not in text
