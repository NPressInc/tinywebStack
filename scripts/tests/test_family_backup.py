"""Static checks for the backup helper and YunoHost hooks."""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
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
    assert "tinyweb_restore.py" in restore
    assert "command -v python3" in restore
    assert "TWS_DASHBOARD_PYTHON" not in restore
    assert "venv/bin/python" not in restore
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
    bad = subprocess.run(
        [str(script), "run-backup", "abc;rm -rf /"],
        check=False,
        env=env,
        capture_output=True,
        text=True,
    )
    assert bad.returncode != 0
    assert not record.exists()
    ok = subprocess.run(
        [str(script), "run-backup", "a" * 32],
        check=False,
        env=env,
        capture_output=True,
        text=True,
    )
    assert ok.returncode == 0
    logged = record.read_text(encoding="utf-8")
    assert f"backup_cli run-backup {'a' * 32}" in logged
    archive = subprocess.run(
        [str(script), "cat-archive", "not-an-archive"],
        check=False,
        env=env,
        capture_output=True,
        text=True,
    )
    assert archive.returncode != 0
    assert "not-an-archive" not in record.read_text(encoding="utf-8")


def test_restore_hook_runs_without_dashboard_venv(tmp_path: Path) -> None:
    work = tmp_path / "archive-work"
    backup = work / "conf" / "tinywebstack"
    snap = backup / "snapshots"
    snap.mkdir(parents=True)
    src = tmp_path / "permissions.db"
    conn = sqlite3.connect(src)
    conn.execute("CREATE TABLE rules (v INTEGER)")
    conn.execute("INSERT INTO rules VALUES (7)")
    conn.commit()
    conn.close()
    source = sqlite3.connect(src)
    dest_db = sqlite3.connect(snap / "permissions.db")
    source.backup(dest_db)
    source.close()
    dest_db.close()
    files = backup / "files" / "etc" / "tinywebstack"
    files.mkdir(parents=True)
    (files / "family-policy.json").write_text('{"ok": true}\n', encoding="utf-8")
    (backup / "manifest.json").write_text(
        json.dumps(
            {
                "sqlite_method": "backup_api",
                "snapshots": ["permissions.db"],
                "files": ["etc/tinywebstack/family-policy.json"],
            }
        ),
        encoding="utf-8",
    )
    shutil.copy(
        ROOT / "family/dashboard/tinywebstack_dashboard/restore_stdlib.py",
        backup / "tinyweb_restore.py",
    )
    restored = tmp_path / "restored"
    restored.mkdir()
    missing_venv = tmp_path / "missing-dashboard-venv" / "bin" / "python"
    proc = subprocess.run(
        ["bash", str(ROOT / "scripts/hooks/restore/99-conf_tinywebstack"), str(work)],
        check=False,
        capture_output=True,
        text=True,
        env={
            "PATH": "/usr/bin:/bin",
            "HOME": str(tmp_path),
            "TWS_DASHBOARD_PYTHON": str(missing_venv),
            "TWS_RESTORE_DEST": str(restored),
            "TWS_BACKUP_HOOK_ALLOW_NON_ROOT": "1",
        },
    )
    assert proc.returncode == 0, proc.stderr
    assert not missing_venv.exists()
    assert (restored / "etc/tinywebstack/family-policy.json").read_text(encoding="utf-8") == '{"ok": true}\n'
    check = sqlite3.connect(restored / "etc/tinywebstack/permissions.db")
    assert list(check.execute("SELECT v FROM rules")) == [(7,)]
    check.close()
