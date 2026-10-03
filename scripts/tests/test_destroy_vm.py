"""Tests for scripts/spark/destroy-vm.sh (stubbed virsh)."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DESTROY_VM = ROOT / "scripts" / "spark" / "destroy-vm.sh"

_VIRSH_STUB = r"""#!/usr/bin/env bash
set -euo pipefail
LOG="${VIRSH_STUB_LOG:?}"
STATE="${VIRSH_STUB_STATE:?}"
case "${1:-}" in
  dominfo)
    [[ -f "$STATE" ]] && exit 0
    exit 1
    ;;
  destroy)
    printf 'destroy %s\n' "$2" >>"$LOG"
    exit 0
    ;;
  undefine)
    domain="$2"
    shift 2
    printf 'undefine %s %s\n' "$domain" "$*" >>"$LOG"
    if [[ "${VIRSH_STUB_UNDEFINE_FAIL:-0}" == "1" ]]; then
      exit 1
    fi
    has_nvram=0
    has_combo=0
    for arg in "$@"; do
      case "$arg" in
        --nvram) has_nvram=1 ;;
        --remove-all-storage) has_combo=1 ;;
      esac
    done
    if [[ "${VIRSH_STUB_REJECT_PLAIN:-1}" == "1" && "$has_nvram" == "0" ]]; then
      echo "cannot undefine domain with nvram" >&2
      exit 1
    fi
    if [[ "${VIRSH_STUB_REJECT_NV_RAM_COMBO:-0}" == "1" && "$has_nvram" == "1" && "$has_combo" == "1" ]]; then
      exit 1
    fi
    rm -f "$STATE"
    exit 0
    ;;
  *)
    echo "stub virsh: unsupported: $*" >&2
    exit 1
    ;;
esac
"""


def _install_virsh_stub(bin_dir: Path, tmp_path: Path) -> tuple[Path, Path]:
    log = tmp_path / "virsh.log"
    state = tmp_path / "domain-defined"
    bin_dir.mkdir(parents=True, exist_ok=True)
    virsh = bin_dir / "virsh"
    virsh.write_text(_VIRSH_STUB, encoding="utf-8")
    virsh.chmod(virsh.stat().st_mode | stat.S_IXUSR)
    return log, state


def _run_destroy(
    tmp_path: Path,
    bin_dir: Path,
    *args: str,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    vm_dir = tmp_path / "vms"
    vm_dir.mkdir(parents=True, exist_ok=True)
    log, state = _install_virsh_stub(bin_dir, tmp_path)
    if extra_env is None or extra_env.get("VIRSH_STUB_NO_DOMAIN") != "1":
        state.write_text("defined\n", encoding="utf-8")
    env = {
        **os.environ,
        "DRY_RUN": "0",
        "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
        "TW_STACK_VM_DIR": str(vm_dir),
        "TW_STACK_SKIP_LOCAL_ENV": "1",
        "LIBVIRT_DEFAULT_URI": "qemu:///system",
        "VIRSH_STUB_LOG": str(log),
        "VIRSH_STUB_STATE": str(state),
        **(extra_env or {}),
    }
    return subprocess.run(
        ["bash", str(DESTROY_VM), *args],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_undefine_uses_nvram_flags_before_plain(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"

    proc = _run_destroy(
        tmp_path,
        bin_dir,
        "family-a",
        extra_env={"VIRSH_STUB_REJECT_NV_RAM_COMBO": "1"},
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    log = tmp_path / "virsh.log"
    undefine_lines = [
        ln for ln in log.read_text(encoding="utf-8").splitlines() if ln.startswith("undefine ")
    ]
    assert undefine_lines[0] == "undefine tws-family-a --nvram --remove-all-storage"
    assert undefine_lines[1] == "undefine tws-family-a --nvram"
    assert not (tmp_path / "domain-defined").exists()


def test_remove_disk_and_seed_iso(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    vm_dir = tmp_path / "vms"
    disk = vm_dir / "tws-family-a.qcow2"
    seed = vm_dir / "tws-family-a" / "seed" / "cloud-init.iso"
    disk.parent.mkdir(parents=True, exist_ok=True)
    disk.write_bytes(b"disk")
    seed.parent.mkdir(parents=True, exist_ok=True)
    seed.write_bytes(b"seed")

    proc = _run_destroy(
        tmp_path,
        bin_dir,
        "family-a",
        "--remove-disk",
        extra_env={"VIRSH_STUB_REJECT_PLAIN": "0"},
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    assert not disk.exists()
    assert not seed.exists()


def test_fails_when_domain_still_defined(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"

    proc = _run_destroy(
        tmp_path,
        bin_dir,
        "family-a",
        extra_env={"VIRSH_STUB_UNDEFINE_FAIL": "1"},
    )
    assert proc.returncode == 1, proc.stderr + proc.stdout
    assert "still defined" in proc.stderr
    assert (tmp_path / "domain-defined").exists()
