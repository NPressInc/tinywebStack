"""Tests for scripts/lib/owntracks_ynh_patch.sh (stubbed curl; no network)."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH_LIB = ROOT / "scripts" / "lib" / "owntracks_ynh_patch.sh"

LEGACY = (
    "https://raw.githubusercontent.com/owntracks/recorder/master/etc/"
    "repo.owntracks.org.gpg.key"
)
V2 = (
    "https://raw.githubusercontent.com/owntracks/recorder/master/etc/"
    "repo-v2.owntracks.org.gpg.key"
)


def _write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _curl_stub(legacy_head_ok: bool) -> str:
    if legacy_head_ok:
        return f"""#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    -w) shift 2; continue ;;
    -o) shift 2; continue ;;
    -*) shift; continue ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *repo.owntracks.org.gpg.key)
    printf '200'
    exit 0
    ;;
esac
printf '404'
exit 22
"""
    return f"""#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    -w) shift 2; continue ;;
    -o) shift 2; continue ;;
    -*) shift; continue ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *repo.owntracks.org.gpg.key)
    printf '404'
    exit 22
    ;;
esac
printf '200'
exit 0
"""


def _run_patch(tmp_path: Path, manifest: Path, legacy_head_ok: bool) -> subprocess.CompletedProcess[str]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _write_executable(bin_dir / "curl", _curl_stub(legacy_head_ok))
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
        "OWNTRACKS_APT_KEY_URL": V2,
    }
    script = f"""
set -euo pipefail
# shellcheck source=scripts/lib/owntracks_ynh_patch.sh
source "{PATCH_LIB}"
owntracks_ynh_patch_manifest_if_needed "{manifest}"
"""
    return subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_manifest_rewritten_when_legacy_key_head_not_200(tmp_path: Path) -> None:
    manifest = tmp_path / "manifest.toml"
    manifest.write_text(
        f'[resources.apt.extras.recorder]\nkey = "{LEGACY}"\n',
        encoding="utf-8",
    )
    proc = _run_patch(tmp_path, manifest, legacy_head_ok=False)
    assert proc.returncode == 0, proc.stderr + proc.stdout
    text = manifest.read_text(encoding="utf-8")
    assert V2 in text
    assert LEGACY not in text
    assert "patched" in (proc.stderr + proc.stdout).lower()


def _git_clone_stub(fixture_repo: Path) -> str:
    return f"""#!/bin/sh
if [ "$1" != clone ]; then
  exit 1
fi
shift
dest=""
while [ $# -gt 0 ]; do
  case "$1" in
    --depth) shift 2; continue ;;
    -*) shift; continue ;;
    *) shift; dest="$1"; break ;;
  esac
done
mkdir -p "$dest"
cp -a "{fixture_repo}"/. "$dest"/
"""


def _run_resolve_install_source(tmp_path: Path, fixture_repo: Path) -> subprocess.CompletedProcess[str]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _write_executable(bin_dir / "curl", _curl_stub(legacy_head_ok=False))
    _write_executable(bin_dir / "git", _git_clone_stub(fixture_repo))
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
        "OWNTRACKS_APT_KEY_URL": V2,
    }
    app_url = "https://github.com/example/owntracks_ynh"
    script = f"""
set -euo pipefail
# shellcheck source=scripts/lib/owntracks_ynh_patch.sh
source "{PATCH_LIB}"
owntracks_ynh_resolve_install_source "{app_url}"
printf 'SRC=%s\\n' "$OWNTRACKS_YNH_INSTALL_SRC"
test -d "$OWNTRACKS_YNH_INSTALL_SRC"
test -f "$OWNTRACKS_YNH_INSTALL_SRC/manifest.toml"
grep -qF "{V2}" "$OWNTRACKS_YNH_INSTALL_SRC/manifest.toml"
grep -qF "{LEGACY}" "$OWNTRACKS_YNH_INSTALL_SRC/manifest.toml" && exit 1 || true
"""
    return subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_resolve_install_source_clone_survives_and_manifest_patched(tmp_path: Path) -> None:
    fixture_repo = tmp_path / "upstream"
    fixture_repo.mkdir()
    (fixture_repo / "manifest.toml").write_text(
        f'[resources.apt.extras.recorder]\nkey = "{LEGACY}"\n',
        encoding="utf-8",
    )
    proc = _run_resolve_install_source(tmp_path, fixture_repo)
    assert proc.returncode == 0, proc.stderr + proc.stdout
    src_line = next(line for line in proc.stdout.splitlines() if line.startswith("SRC="))
    src_path = src_line.removeprefix("SRC=")
    assert Path(src_path).is_dir()
    manifest = Path(src_path) / "manifest.toml"
    text = manifest.read_text(encoding="utf-8")
    assert V2 in text
    assert LEGACY not in text


def test_manifest_untouched_when_legacy_key_head_is_200(tmp_path: Path) -> None:
    manifest = tmp_path / "manifest.toml"
    manifest.write_text(
        f'[resources.apt.extras.recorder]\nkey = "{LEGACY}"\n',
        encoding="utf-8",
    )
    proc = _run_patch(tmp_path, manifest, legacy_head_ok=True)
    assert proc.returncode == 0, proc.stderr + proc.stdout
    assert manifest.read_text(encoding="utf-8") == (
        f'[resources.apt.extras.recorder]\nkey = "{LEGACY}"\n'
    )
    assert "patched" not in (proc.stderr + proc.stdout).lower()
