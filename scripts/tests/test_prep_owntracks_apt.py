"""Tests for scripts/vm/prep-owntracks-apt.sh (stubbed curl/apt; no real install)."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PREP = ROOT / "scripts" / "vm" / "prep-owntracks-apt.sh"


def _write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def test_legacy_key_404_reaches_deb_fallback(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log_file = tmp_path / "prep.log"
    key_dir = tmp_path / "etc" / "apt" / "trusted.gpg.d"
    key_dir.mkdir(parents=True)
    key_gpg = key_dir / "owntracks.gpg"

    _write_executable(
        bin_dir / "id",
        "#!/bin/sh\nprintf '0\\n'\n",
    )
    _write_executable(
        bin_dir / "gpg",
        '#!/bin/sh\nif [ "$1" = "--dearmor" ]; then cp "$5" "$4"; else exit 1; fi\n',
    )
    _write_executable(
        bin_dir / "dpkg",
        """#!/bin/sh
case "$1" in
  --print-architecture) echo arm64; exit 0 ;;
  -s) exit 1 ;;
  -i) exit 0 ;;
esac
exit 1
""",
    )
    _write_executable(
        bin_dir / "apt-get",
        """#!/bin/sh
echo "apt-get $*" >>"$APT_LOG"
case "$1" in
  update) exit 0 ;;
  install) exit 100 ;;
esac
exit 1
""",
    )
    _write_executable(
        bin_dir / "curl",
        """#!/bin/sh
url=""
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2; continue ;;
    -*) shift; continue ;;
    *) url="$1"; shift ;;
  esac
done
pkgs='Package: ot-recorder
Filename: pool/main/o/ot-recorder_test_arm64.deb'
case "$url" in
  *repo-v2.owntracks.org.gpg.key)
    if [ -n "$out" ]; then echo 'BEGIN PGP PUBLIC KEY BLOCK stub' >"$out"; else echo 'BEGIN PGP PUBLIC KEY BLOCK stub'; fi
    exit 0
    ;;
  *repo.owntracks.org.gpg.key)
    exit 22
    ;;
  */Packages)
    if [ -n "$out" ]; then echo "$pkgs" >"$out"; else echo "$pkgs"; fi
    exit 0
    ;;
  *ot-recorder_test_arm64.deb)
    if [ -n "$out" ]; then echo 'fake-deb' >"$out"; else echo 'fake-deb'; fi
    exit 0
    ;;
esac
exit 1
""",
    )

    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
        "APT_LOG": str(log_file),
        "OWNTRACKS_APT_KEY_GPG": str(key_gpg),
        "TW_STACK_ROOT": str(ROOT),
    }
    proc = subprocess.run(
        ["bash", str(PREP)],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    combined = proc.stderr + proc.stdout
    assert "WARN: could not install legacy OwnTracks apt key" in combined
    assert "Installed ot-recorder from" in combined or "direct .deb install" in combined.lower()
    assert key_gpg.is_file()


def test_script_warns_on_legacy_key_failure() -> None:
    text = PREP.read_text(encoding="utf-8")
    assert "WARN: could not install legacy OwnTracks apt key" in text
    assert "install_deb_fallback" in text
    legacy_idx = text.find("LEGACY_KEY_URL")
    fallback_idx = text.rfind("install_deb_fallback")
    assert legacy_idx >= 0 and fallback_idx > legacy_idx
