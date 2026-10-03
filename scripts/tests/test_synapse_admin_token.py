"""Tests for scripts/lib/synapse-admin-token.sh (stubbed register/curl)."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SYNAPSE_TOKEN_SH = ROOT / "scripts" / "lib" / "synapse-admin-token.sh"


def _run_provision(tmp_path: Path, bin_dir: Path, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    etc = tmp_path / "etc"
    matrix_dir = etc / "matrix-synapse"
    matrix_dir.mkdir(parents=True)
    secrets = etc / "tinywebstack" / "secrets"
    secrets.mkdir(parents=True, exist_ok=True)
    token_file = etc / "tinywebstack" / "synapse-admin-token"
    pw_file = secrets / "synapse-admin.password"
    hs = matrix_dir / "homeserver.yaml"
    hs.write_text("server_name: home.example.com\n", encoding="utf-8")

    register_log = tmp_path / "register.stdin"
    curl_log = tmp_path / "curl.log"

    register = bin_dir / "register_new_matrix_user"
    register.write_text(
        f"""#!/usr/bin/env bash
while read -r line; do
  printf '%s\\n' "$line" >>"{register_log}"
done
exit 0
""",
        encoding="utf-8",
    )
    register.chmod(register.stat().st_mode | stat.S_IXUSR)

    curl_sh = bin_dir / "curl"
    curl_sh.write_text(
        f"""#!/usr/bin/env bash
out=""
url=""
for arg in "$@"; do
  case "$arg" in
    http://*|https://*) url="$arg" ;;
  esac
done
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\\n' "$url" >>"{curl_log}"
if [[ -n "$out" ]]; then
  printf '{{"access_token":"stub-token"}}' >"$out"
fi
printf '200'
exit 0
""",
        encoding="utf-8",
    )
    curl_sh.chmod(curl_sh.stat().st_mode | stat.S_IXUSR)

    script = rf"""
set -euo pipefail
export PATH="{bin_dir}:$PATH"
export SYNAPSE_ADMIN_PASSWORD_FILE="{pw_file}"
export TWS_SYNAPSE_HOMESERVER_YAML="{hs}"
export TWS_SYNAPSE_REGISTER_BIN="{register}"
source scripts/lib/synapse-admin-token.sh
provision_synapse_admin_token home.example.com "{token_file}"
"""
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
        **(extra_env or {}),
    }
    return subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_register_gets_password_twice_and_local_login_first(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    proc = _run_provision(tmp_path, bin_dir)
    assert proc.returncode == 0, proc.stderr + proc.stdout

    register_log = tmp_path / "register.stdin"
    lines = register_log.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 2
    assert lines[0] == lines[1]
    assert lines[0]

    curl_log = tmp_path / "curl.log"
    urls = [ln for ln in curl_log.read_text(encoding="utf-8").splitlines() if ln]
    login_urls = [u for u in urls if "_matrix/client/v3/login" in u]
    assert login_urls[0] == "http://127.0.0.1:8008/_matrix/client/v3/login"
    assert len(login_urls) == 1

    token_file = tmp_path / "etc" / "tinywebstack" / "synapse-admin-token"
    assert token_file.read_text(encoding="utf-8").strip() == "stub-token"


def test_reuses_stored_admin_password_on_rerun(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    secrets = tmp_path / "etc" / "tinywebstack" / "secrets"
    secrets.mkdir(parents=True)
    pw_file = secrets / "synapse-admin.password"
    pw_file.write_text("fixed-secret-password12", encoding="utf-8")

    proc = _run_provision(tmp_path, bin_dir)
    assert proc.returncode == 0, proc.stderr + proc.stdout

    register_log = tmp_path / "register.stdin"
    lines = register_log.read_text(encoding="utf-8").splitlines()
    assert lines[0] == "fixed-secret-password12"
    assert lines[1] == "fixed-secret-password12"


def test_synapse_admin_password_file_mode(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    proc = _run_provision(tmp_path, bin_dir)
    assert proc.returncode == 0, proc.stderr + proc.stdout
    pw_file = tmp_path / "etc" / "tinywebstack" / "secrets" / "synapse-admin.password"
    assert pw_file.is_file()
    mode = stat.S_IMODE(pw_file.stat().st_mode)
    assert mode == 0o600
