"""S5.4 packaging tests: build both packages from source and exercise the
installed artifact (import the Synapse module, run the calendar CLIs from
their console entry points) — not the source tree.

Method: ``pip install --target <tmpdir> --no-deps --no-build-isolation`` on
each package dir. This builds a real wheel from pyproject.toml with the
in-tree setuptools backend, so it works fully offline in CI and on dev
machines. If the base python lacks setuptools or the build otherwise needs
network that isn't there, the test skips rather than fails (same spirit as
validate.sh skipping pytest when pip install fails).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
FAMILY_SRC = ROOT / "family" / "synapse_module"
CALENDAR_SRC = ROOT / "family" / "calendar_module"

OFFLINE_HINTS = (
    "network",
    "connection",
    "resolve",
    "offline",
    "timeout",
    "proxy",
    "no module named 'setuptools'",
)


def _base_has_setuptools() -> bool:
    try:
        import setuptools  # noqa: F401

        return True
    except ImportError:
        return False


pytestmark = pytest.mark.skipif(
    not _base_has_setuptools(),
    reason="setuptools unavailable in base python; wheel build cannot run offline",
)


def _install_offline(target: Path, src: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    cmd = [
        sys.executable,
        "-m",
        "pip",
        "install",
        "--target",
        str(target),
        "--no-deps",
        "--no-input",
        "--no-build-isolation",
        "--upgrade",
        str(src),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == 0:
        return
    blob = (r.stdout + r.stderr).lower()
    if any(h in blob for h in OFFLINE_HINTS):
        pytest.skip("offline build failed (no build backend / no network); skipped")
    raise AssertionError(f"pip install failed for {src}:\n{r.stdout}\n{r.stderr}")


def _run_installed(target: Path, *args: str, env=None) -> subprocess.CompletedProcess:
    # -S: skip site processing so __editable__ .pth finders from the
    # developer's base env (the repo is pip-installed -e in CI/dev) can't
    # shadow the freshly installed package. Base site-packages is appended
    # to PYTHONPATH explicitly — .pth files are NOT processed from
    # PYTHONPATH, so editable finders stay dormant while optional deps
    # (caldav/vobject) remain importable.
    base_site = sysconfig.get_paths()["purelib"]
    paths = [str(target), base_site]
    try:
        import site

        usersite = site.getusersitepackages()
        if usersite and Path(usersite).is_dir():
            paths.append(usersite)
    except Exception:  # noqa: BLE001 - best-effort optional dep discovery
        pass
    e = {**os.environ, "PYTHONPATH": os.pathsep.join(paths)}
    # cwd=target.parent so nothing leaks the source tree onto sys.path.
    if env:
        e.update(env)
    return subprocess.run(
        [sys.executable, "-S", *args],
        capture_output=True,
        text=True,
        env=e,
        cwd=str(target.parent),
    )


@pytest.fixture(scope="module")
def family_target(tmp_path_factory) -> Path:
    target = tmp_path_factory.mktemp("family-installed") / "site"
    _install_offline(target, FAMILY_SRC)
    return target


@pytest.fixture(scope="module")
def calendar_target(tmp_path_factory) -> Path:
    target = tmp_path_factory.mktemp("calendar-installed") / "site"
    _install_offline(target, CALENDAR_SRC)
    return target


def test_family_module_imports_from_installed_package(family_target: Path) -> None:
    """Import tinywebstack_family from the installed wheel, cwd OUTSIDE the
    source tree so a stray sys.path leak can't fake it."""
    r = _run_installed(
        family_target,
        "-c",
        "import tinywebstack_family;"
        "assert tinywebstack_family.FamilySpamCheckerModule;"
        "assert 'site' in tinywebstack_family.__file__;"
        "print('ok')",
    )
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "ok"


def test_calendar_package_imports_from_installed_site(calendar_target: Path) -> None:
    r = _run_installed(
        calendar_target,
        "-c",
        "import tinywebstack_calendar;"
        "assert 'site' in tinywebstack_calendar.__file__;"
        "from tinywebstack_calendar.naming import family_group_name;"
        "assert family_group_name('home.example.com','home');"
        "print('ok')",
    )
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "ok"


def test_calendar_console_scripts_help(calendar_target: Path) -> None:
    """Console entry points from the built wheel: --help must exit 0 with the
    real CLI surface. verify imports caldav/vobject; if those aren't present
    in the base env the entry point can't load — skip that half (the lab
    scripts never use the entry point; they call python -m themselves)."""
    bin_dir = calendar_target / "bin"
    for script in ("tinywebstack-calendar-setup", "tinywebstack-calendar-verify"):
        assert (bin_dir / script).exists() or (bin_dir / f"{script}.exe").exists(), (
            f"console script {script} missing from built wheel"
        )

    r = _run_installed(calendar_target, str(bin_dir / "tinywebstack-calendar-setup"), "--help")
    assert r.returncode == 0, r.stderr
    assert "--occ-path" in r.stdout  # setup's real surface, not just argparse boilerplate

    r = _run_installed(calendar_target, str(bin_dir / "tinywebstack-calendar-verify"), "--help")
    if r.returncode != 0 and "No module named 'caldav'" in r.stderr:
        pytest.skip("caldav unavailable offline; verify entry-point import skipped")
    assert r.returncode == 0, r.stderr
    assert "invite-roundtrip" in r.stdout


def test_calendar_module_main_still_gives_hint(calendar_target: Path) -> None:
    """Bare `python -m tinywebstack_calendar` keeps exiting 2 with the hint —
    the lab scripts depend on `-m tinywebstack_calendar.setup|verify`."""
    r = _run_installed(calendar_target, "-m", "tinywebstack_calendar")
    assert r.returncode == 2
    assert "tinywebstack_calendar.setup" in r.stderr


def test_family_pyproject_keeps_venv_clean() -> None:
    """The Synapse module is loaded by dotted path from conf.d, so it must NOT
    ship console scripts and must keep zero runtime deps (nothing extra may
    leak into the Synapse venv)."""
    tomlo = (FAMILY_SRC / "pyproject.toml").read_text()
    assert "[project.scripts]" not in tomlo
    assert "dependencies = []" in tomlo


def test_calendar_pyproject_declares_deps_and_scripts() -> None:
    tomlo = (CALENDAR_SRC / "pyproject.toml").read_text()
    assert "tinywebstack-calendar-setup" in tomlo
    assert "tinywebstack-calendar-verify" in tomlo
    assert "dependencies = []" in tomlo
    assert "caldav" in tomlo and "vobject" in tomlo  # still in verify/test extras


def test_build_system_declared_in_both() -> None:
    for src in (FAMILY_SRC, CALENDAR_SRC):
        tomlo = (src / "pyproject.toml").read_text()
        assert "[build-system]" in tomlo, src
        assert "setuptools" in tomlo, src
