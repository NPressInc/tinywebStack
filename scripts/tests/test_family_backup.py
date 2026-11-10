"""Static checks for the backup helper and YunoHost hooks."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_install_does_not_enable_a_backup_timer() -> None:
    text = (ROOT / "scripts/vm/install-family-dashboard.sh").read_text(encoding="utf-8")
    assert "tws-family-backup-privileged" in text
    assert "99-conf_tinywebstack" in text
    assert "TWS_BACKUP_HELPER" in text
    assert "systemctl enable tinywebstack-family-backup" not in text
    assert "yunohost backup create" not in text


def test_hooks_snapshot_through_python_and_do_not_tar_live_dbs() -> None:
    backup = (ROOT / "scripts/hooks/backup/99-conf_tinywebstack").read_text(encoding="utf-8")
    restore = (ROOT / "scripts/hooks/restore/99-conf_tinywebstack").read_text(encoding="utf-8")
    assert "backup_hook snapshot" in backup
    assert "tar " not in backup
    assert "backup_hook restore" in restore
    assert "yunohost backup restore" not in restore
    subprocess.run(["bash", "-n", str(ROOT / "scripts/hooks/backup/99-conf_tinywebstack")], check=True)
    subprocess.run(["bash", "-n", str(ROOT / "scripts/hooks/restore/99-conf_tinywebstack")], check=True)
    subprocess.run(["bash", "-n", str(ROOT / "scripts/vm/family-backup-privileged.sh")], check=True)


def test_privileged_helper_rejects_unknown_commands(tmp_path: Path) -> None:
    record = tmp_path / "record"
    fake = tmp_path / "python"
    fake.write_text(
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$RECORD\"\n",
        encoding="utf-8",
    )
    fake.chmod(0o755)
    script = ROOT / "scripts/vm/family-backup-privileged.sh"
    env = {
        **os.environ,
        "TWS_PRIVILEGED_ALLOW_NON_ROOT": "1",
        "TWS_DASHBOARD_PYTHON": str(fake),
        "RECORD": str(record),
    }
    unknown = subprocess.run([str(script), "rm", "-rf", "/"], check=False, env=env, capture_output=True, text=True)
    assert unknown.returncode != 0
    assert not record.exists()
    extra = subprocess.run([str(script), "preflight", "extra"], check=False, env=env, capture_output=True, text=True)
    assert extra.returncode != 0
    ok = subprocess.run(
        [str(script), "run-backup", "abc;rm -rf /"],
        check=False,
        env=env,
        capture_output=True,
        text=True,
    )
    assert ok.returncode == 0
    logged = record.read_text(encoding="utf-8")
    assert "backup_cli run-backup abc;rm -rf /" in logged
    assert not (tmp_path / "rf").exists()
