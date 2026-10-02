"""S5.4: tests for scripts/vm/family-module-post-upgrade.sh (and the pip
install path of install-family-module.sh) against a sandboxed fake Synapse
venv tree — wipe detection, re-install invocation, and healthy no-op.

The fake node tree mirrors the VM layout (what remote-run.sh rsyncs to
/opt/tinywebstack): lib/ (scripts/lib), vm/ (scripts/vm), family/. The fake
Synapse venv is a venv-style bin/ with a `pip` stub that "installs" by
copying the package out of the source dir passed on its command line, and a
`python` wrapper that execs the real interpreter with the fake
site-packages on PYTHONPATH. No root, no systemctl, no network.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]

INSTALLER = "install-family-module.sh"
POST_UPGRADE = "family-module-post-upgrade.sh"


def _make_node_tree(tmp_path: Path) -> Path:
    """Fake /opt/tinywebstack VM tree + fake Synapse venv."""
    node = tmp_path / "node"
    (node / "lib").mkdir(parents=True)
    shutil.copytree(ROOT / "scripts" / "lib", node / "lib", dirs_exist_ok=True)
    (node / "vm").mkdir()
    for name in (INSTALLER, POST_UPGRADE):
        shutil.copy2(ROOT / "scripts" / "vm" / name, node / "vm" / name)
    shutil.copytree(
        ROOT / "family",
        node / "family",
        ignore=shutil.ignore_patterns("__pycache__", "*.egg-info", ".pytest_cache", "tests"),
    )

    venv = node / "synapse-venv"
    (venv / "bin").mkdir(parents=True)
    (venv / "lib" / "site-packages").mkdir(parents=True)

    pip_stub = venv / "bin" / "pip"
    pip_stub.write_text(
        """#!/usr/bin/env bash
# Fake Synapse-venv pip: record the call, then install by copying the
# package directory out of the source dir given as the last argument.
echo "$*" >> "${FAKE_PIP_LOG:?FAKE_PIP_LOG not set}"
src="${*: -1}"
site="$(cd "$(dirname "$0")/.." && pwd)/lib/site-packages"
if [[ -d "$src/tinywebstack_family" ]]; then
  rm -rf "${site}/tinywebstack_family"
  cp -r "$src/tinywebstack_family" "${site}/"
elif [[ -d "$src/tinywebstack_permissions" ]]; then
  rm -rf "${site}/tinywebstack_permissions"
  cp -r "$src/tinywebstack_permissions" "${site}/"
else
  echo "fake pip: $src is not tinywebstack-family or tinywebstack_permissions source" >&2
  exit 1
fi
"""
    )
    python_stub = venv / "bin" / "python"
    python_stub.write_text(
        f"""#!/bin/sh
# Fake Synapse-venv python: real interpreter, fake site-packages on path.
# -S so __editable__ .pth finders from the dev/CI base env cannot shadow the
# fake site-packages (PYTHONPATH is honored without .pth processing, which is
# exactly the isolation a real Synapse venv has).
d=$(dirname "$0")
PYTHONPATH="$d/../lib/site-packages${{PYTHONPATH:+:$PYTHONPATH}}" \\
  exec {sys.executable} -S "$@"
"""
    )
    for stub in (pip_stub, python_stub):
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP)
    return node


def _base_env(node: Path, tmp_path: Path) -> dict[str, str]:
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(tmp_path),
        "LANG": "C.UTF-8",
        "TWS_ALLOW_NONROOT": "1",
        "TWS_SKIP_RESTART": "1",
        "TWS_SYNAPSE_PIP": str(node / "synapse-venv" / "bin" / "pip"),
        "TWS_FAMILY_MODULE_VENV": str(node / "synapse-venv"),
        "TWS_POLICY_PATH": str(tmp_path / "etc" / "family-policy.json"),
        "TWS_SYNAPSE_CONF_D": str(tmp_path / "conf.d"),
        "FAKE_PIP_LOG": str(tmp_path / "fake-pip.log"),
    }


def _run(node: Path, script: str, env: dict, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(node / "vm" / script), *args],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(node),
    )


def _module_importable(venv: Path) -> bool:
    probe = venv / "bin" / "python"
    r = subprocess.run(
        [
            str(probe),
            "-c",
            "import tinywebstack_family, tinywebstack_permissions;"
            "assert tinywebstack_family.FamilySpamCheckerModule;"
            "assert tinywebstack_permissions.PermissionsDB;"
            "assert 'site-packages' in tinywebstack_family.__file__",
        ],
        capture_output=True,
        text=True,
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
    )
    return r.returncode == 0


@pytest.fixture()
def node(tmp_path: Path) -> Path:
    return _make_node_tree(tmp_path)


def _wipe(venv: Path) -> None:
    """Simulate `yunohost app upgrade synapse` recreating the venv."""
    site = venv / "lib" / "site-packages"
    shutil.rmtree(site / "tinywebstack_family", ignore_errors=True)
    shutil.rmtree(site / "tinywebstack_permissions", ignore_errors=True)


def test_post_upgrade_detects_wipe_and_reinstalls(node: Path, tmp_path: Path) -> None:
    venv = node / "synapse-venv"
    env = _base_env(node, tmp_path)

    # Wipe first (fresh tree = wiped venv); sanity: module absent.
    _wipe(venv)
    assert not _module_importable(venv)

    r = _run(node, POST_UPGRADE, env)
    assert r.returncode == 0, r.stderr
    assert "MISSING" in r.stderr
    assert "re-applying" in r.stderr
    assert "re-applied" in r.stderr
    assert _module_importable(venv), "post-upgrade must leave the module importable"

    pip_calls = Path(env["FAKE_PIP_LOG"]).read_text()
    assert "install" in pip_calls and "tinywebstack_family" not in pip_calls
    assert "force-reinstall" in pip_calls  # survives stale same-version copies
    assert (tmp_path / "conf.d" / "tinywebstack-family.yaml").is_file()
    assert (tmp_path / "etc" / "family-policy.json").is_file()


def test_post_upgrade_is_noop_when_healthy(node: Path, tmp_path: Path) -> None:
    env = _base_env(node, tmp_path)

    # Install once via the post-upgrade path itself.
    r = _run(node, POST_UPGRADE, env)
    assert r.returncode == 0, r.stderr
    assert "MISSING" in r.stderr  # was wiped (fresh tree)
    first_calls = Path(env["FAKE_PIP_LOG"]).read_text()

    # Healthy run: no pip invocation, no installer run.
    Path(env["FAKE_PIP_LOG"]).unlink()
    r = _run(node, POST_UPGRADE, env)
    assert r.returncode == 0, r.stderr
    assert "nothing to do" in r.stderr
    assert "re-applying" not in r.stderr
    assert not Path(env["FAKE_PIP_LOG"]).exists()
    assert "install" in first_calls


def test_post_upgrade_dry_run_wipe_makes_no_changes(node: Path, tmp_path: Path) -> None:
    venv = node / "synapse-venv"
    _wipe(venv)
    env = _base_env(node, tmp_path)
    env["DRY_RUN"] = "1"

    r = _run(node, POST_UPGRADE, env)
    assert r.returncode == 0, r.stderr
    assert "MISSING" in r.stderr
    assert "DRY_RUN" in r.stderr
    assert not Path(env["FAKE_PIP_LOG"]).exists()
    assert not _module_importable(venv)
    assert not (tmp_path / "conf.d" / "tinywebstack-family.yaml").exists()


def test_installer_idempotent_direct_runs(node: Path, tmp_path: Path) -> None:
    env = _base_env(node, tmp_path)
    for i in range(2):
        r = _run(node, INSTALLER, env)
        assert r.returncode == 0, f"run {i}: {r.stderr}"
        assert "Synapse family module installed" in r.stderr
        assert _module_importable(node / "synapse-venv")
    assert (tmp_path / "conf.d" / "tinywebstack-family.yaml").is_file()
    # Second run reports the snippet as unchanged (idempotent config).
    r = _run(node, INSTALLER, env)
    assert "unchanged" in r.stderr


def test_installer_dry_run_writes_nothing(node: Path, tmp_path: Path) -> None:
    env = _base_env(node, tmp_path)
    env["DRY_RUN"] = "1"
    r = _run(node, INSTALLER, env)
    assert r.returncode == 0, r.stderr
    assert "DRY_RUN" in r.stderr
    assert not Path(env["FAKE_PIP_LOG"]).exists()
    assert not (tmp_path / "conf.d" / "tinywebstack-family.yaml").exists()
    assert not (tmp_path / "etc" / "family-policy.json").exists()


def test_installer_writes_expected_snippet(node: Path, tmp_path: Path) -> None:
    """The conf.d snippet must still point Synapse at the module by dotted
    path (the whole reason packaging works) and keep E2EE off."""
    env = _base_env(node, tmp_path)
    r = _run(node, INSTALLER, env)
    assert r.returncode == 0, r.stderr
    snippet = (tmp_path / "conf.d" / "tinywebstack-family.yaml").read_text()
    assert "tinywebstack_family.module.FamilySpamCheckerModule" in snippet
    assert "encryption_enabled_by_default_for_room_type" in snippet
    assert f"policy_path: {env['TWS_POLICY_PATH']}" in snippet
    assert "permissions_db:" in snippet
    import yaml

    data = yaml.safe_load(snippet)
    assert data["modules"][0]["module"] == (
        "tinywebstack_family.module.FamilySpamCheckerModule"
    )
