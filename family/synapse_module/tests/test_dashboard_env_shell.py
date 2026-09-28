"""Ensure dashboard.env selective load works with quoted values (no bash source)."""

import subprocess
from pathlib import Path


def test_load_dashboard_env_selective_exports_server_name(tmp_path: Path) -> None:
    env = tmp_path / "dashboard.env"
    env.write_text(
        'TWS_SERVER_NAME=test.local\n'
        'TWS_YUNOHOST_PRIV_HELPER="sudo /usr/local/sbin/tws-family-dashboard-privileged"\n',
        encoding="utf-8",
    )
    repo = Path(__file__).resolve().parents[3]
    script = repo / "scripts" / "lib" / "dashboard_env.sh"
    out = subprocess.run(
        [
            "bash",
            "-c",
            f'source "{script}"; TW_STACK_ROOT="{repo}"; '
            f'load_dashboard_env_selective "{env}"; printf "%s" "$TWS_SERVER_NAME"',
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    assert out.stdout == "test.local"
