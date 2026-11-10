"""Backup policy, hook snapshots, and the parent backup page."""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import tarfile
import time
from datetime import datetime, timedelta, timezone
from io import BytesIO
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app
from tinywebstack_dashboard.backup import (
    TIMER_NAME,
    ArchiveRecord,
    BackupError,
    Settings,
    TargetSelection,
    apply_schedule,
    archive_file_ok,
    build_create_command,
    build_delete_command,
    connect,
    coverage_rows,
    default_settings,
    insert_job,
    load_settings,
    new_archive_id,
    on_calendar,
    reconcile_jobs,
    redact,
    render_systemd_units,
    retention_ids,
    select_targets,
    update_job,
    validate_export_path,
    validate_settings,
)
from tinywebstack_dashboard.backup_cli import execute_backup_job
from tinywebstack_dashboard.backup_hook import (
    HookLayout,
    restore_destination,
    restore_state,
    snapshot_state,
)

PARENT = {"YNH_USER": "parent1"}
REPO = Path(__file__).resolve().parents[3]


def _write_archive(path: Path, *, with_marker: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w") as tar:
        payload = b'{"sqlite_method":"backup_api"}\n' if with_marker else b"nope\n"
        name = "conf/tinywebstack/manifest.json" if with_marker else "conf/ldap/note.txt"
        info = tarfile.TarInfo(name)
        info.size = len(payload)
        tar.addfile(info, BytesIO(payload))


def _iso(moment: datetime) -> str:
    return moment.replace(microsecond=0).isoformat()


@pytest.fixture
def backup_env(tmp_path, monkeypatch):
    state = tmp_path / "state"
    settings = tmp_path / "backup-settings.json"
    archives = tmp_path / "archives"
    archives.mkdir()
    monkeypatch.setenv("TWS_BACKUP_STATE_DIR", str(state))
    monkeypatch.setenv("TWS_BACKUP_SETTINGS_PATH", str(settings))
    monkeypatch.setenv("TWS_BACKUP_ARCHIVE_DIR", str(archives))
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_GROUPS", json.dumps({"parents": ["parent1"], "kids": ["kid1"]}))
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    log = tmp_path / "helper.log"
    pids = tmp_path / "pids"
    script = tmp_path / "helper.sh"
    script.write_text(
        f"""#!/bin/sh
printf '%s\\n' "$*" >> "{log}"
cmd=$1
case "$cmd" in
  preflight)
    if [ "${{HELPER_FREE:-ok}}" = "low" ]; then
      printf '%s\\n' '{{"free_bytes": 10, "min_free_bytes": 2147483648, "ok": false}}'
    else
      printf '%s\\n' '{{"free_bytes": 5000000000, "min_free_bytes": 2147483648, "ok": true}}'
    fi
    ;;
  list-archives)
    printf '%s\\n' '{{"archives":[]}}'
    ;;
  run-backup|copy-archive)
    echo $$ >> "{pids}"
    sleep "${{HELPER_SLEEP:-0}}"
    ;;
  cat-archive)
    if [ "$2" = "tinyweb-20260101-000001" ]; then
      echo 'password=hunter2' >&2
      exit 1
    fi
    printf 'tar-bytes'
    ;;
  apply-schedule)
    ;;
  *)
    echo unknown >&2
    exit 1
    ;;
esac
""",
        encoding="utf-8",
    )
    script.chmod(0o755)
    monkeypatch.setenv("TWS_BACKUP_HELPER", str(script))
    policy = tmp_path / "family-policy.json"
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-a.test",
                "kids": {},
                "parent_mxids": ["@parent1:family-a.test"],
                "trusted_domains": [],
                "reject_encryption": False,
            }
        ),
        encoding="utf-8",
    )
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="smith.tinyweb.win",
        csrf_secret="test-secret",
    )
    client = TestClient(create_app(cfg))
    return {
        "client": client,
        "log": log,
        "pids": pids,
        "settings": settings,
        "state": state,
        "archives": archives,
        "tmp": tmp_path,
    }


def _csrf(client: TestClient) -> str:
    page = client.get("/backup", headers=PARENT)
    assert page.status_code == 200, page.text
    marker = 'name="csrf" value="'
    assert marker in page.text
    return page.text.split(marker, 1)[1].split('"', 1)[0]


def _stop_helpers(pids: Path) -> None:
    if not pids.is_file():
        return
    for line in pids.read_text(encoding="utf-8").split():
        try:
            os.kill(int(line), 15)
        except OSError:
            pass


def test_page_requires_parent_and_hides_secrets(backup_env):
    client = backup_env["client"]
    assert client.get("/backup").status_code == 401
    assert client.get("/backup", headers={"Remote-User": "parent1"}).status_code == 401
    assert client.get("/backup", headers={"YNH_USER": "kid1"}).status_code == 403
    denied = client.post("/backup/now", headers={"YNH_USER": "kid1"}, data={"csrf": "x"})
    assert denied.status_code == 403
    page = client.get("/backup", headers=PARENT)
    assert page.status_code == 200
    assert "same computer" in page.text
    assert "does not start a restore" in page.text
    assert "Family logins" in page.text
    assert "Chats and files sent in chat" in page.text
    assert "Calendars" in page.text
    assert "Events" in page.text
    assert "Family rules and phone sign-ins" in page.text
    assert "Jellyfin" in page.text
    assert "recovery key" in page.text
    assert "Automatic backups are <strong>off</strong>" in page.text
    assert 'value="off" selected' in page.text or 'value="off"  selected' in page.text or "selected" in page.text
    assert "password" not in page.text.lower() or "password file" in page.text.lower()
    assert not backup_env["settings"].exists()


def test_csrf_and_unknown_restore_route(backup_env):
    client = backup_env["client"]
    missing = client.post("/backup/now", headers=PARENT, data={})
    assert missing.status_code == 400
    assert client.post("/backup/restore", headers=PARENT, data={"csrf": _csrf(client)}).status_code == 404


def test_low_space_and_conflict_do_not_start_work(backup_env, monkeypatch):
    client = backup_env["client"]
    monkeypatch.setenv("HELPER_FREE", "low")
    low = client.post("/backup/now", headers=PARENT, data={"csrf": _csrf(client)})
    assert low.status_code == 409
    assert "free disk space" in low.text
    log = backup_env["log"].read_text(encoding="utf-8")
    assert "run-backup" not in log

    monkeypatch.setenv("HELPER_FREE", "ok")
    conn = connect(backup_env["state"])
    job = insert_job(conn, kind="backup", actor="parent1")
    update_job(conn, job["id"], status="running", phase="backup", pid=os.getpid())
    conn.close()
    busy = client.post("/backup/now", headers=PARENT, data={"csrf": _csrf(client)})
    assert busy.status_code == 409
    assert "already running" in busy.text
    assert backup_env["log"].read_text(encoding="utf-8").count("run-backup") == 0


def test_backup_now_returns_before_helper_finishes(backup_env, monkeypatch):
    monkeypatch.setenv("HELPER_SLEEP", "30")
    client = backup_env["client"]
    started = time.monotonic()
    try:
        response = client.post(
            "/backup/now",
            headers=PARENT,
            data={"csrf": _csrf(client)},
            follow_redirects=False,
        )
        elapsed = time.monotonic() - started
        assert response.status_code == 303
        assert elapsed < 5
        assert "run-backup" in backup_env["log"].read_text(encoding="utf-8")
    finally:
        _stop_helpers(backup_env["pids"])


def test_failed_job_and_download_do_not_leak_secrets(backup_env):
    conn = connect(backup_env["state"])
    failed = insert_job(conn, kind="backup", actor="parent1")
    update_job(
        conn,
        failed["id"],
        status="failed",
        phase="failed",
        detail="password=hunter2 token=tws_supersecret",
    )
    ok = insert_job(conn, kind="backup", actor="parent1", archive_id="tinyweb-20260101-000000")
    update_job(conn, ok["id"], status="succeeded", phase="succeeded", archive_id="tinyweb-20260101-000000")
    leaked = insert_job(conn, kind="backup", actor="parent1", archive_id="tinyweb-20260101-000001")
    update_job(conn, leaked["id"], status="succeeded", phase="succeeded", archive_id="tinyweb-20260101-000001")
    conn.close()
    client = backup_env["client"]
    page = client.get("/backup", headers=PARENT)
    assert "hunter2" not in page.text
    assert "tws_supersecret" not in page.text
    assert "yunohost backup restore tinyweb-20260101-000000" in page.text
    assert "does not start a restore" in page.text
    bad = client.post(
        "/backup/archives/tinyweb-not-a-date/download",
        headers=PARENT,
        data={"csrf": _csrf(client)},
    )
    assert bad.status_code == 400
    missing = client.post(
        "/backup/archives/tinyweb-20260102-000000/download",
        headers=PARENT,
        data={"csrf": _csrf(client)},
    )
    assert missing.status_code == 404
    assert "cat-archive" not in backup_env["log"].read_text(encoding="utf-8")
    secret = client.post(
        "/backup/archives/tinyweb-20260101-000001/download",
        headers=PARENT,
        data={"csrf": _csrf(client)},
    )
    assert secret.status_code == 404
    assert "hunter2" not in secret.text
    downloaded = client.post(
        "/backup/archives/tinyweb-20260101-000000/download",
        headers=PARENT,
        data={"csrf": _csrf(client)},
    )
    assert downloaded.status_code == 200
    assert downloaded.content == b"tar-bytes"
    assert "attachment" in downloaded.headers["content-disposition"]
    assert downloaded.headers["cache-control"] == "no-store"
    kid = client.post(
        "/backup/archives/tinyweb-20260101-000000/download",
        headers={"YNH_USER": "kid1"},
        data={"csrf": _csrf(client)},
    )
    assert kid.status_code == 403


def test_copy_path_is_restricted(backup_env):
    conn = connect(backup_env["state"])
    job = insert_job(conn, kind="backup", actor="parent1", archive_id="tinyweb-20260101-000000")
    update_job(conn, job["id"], status="succeeded", phase="succeeded", archive_id="tinyweb-20260101-000000")
    conn.close()
    client = backup_env["client"]
    csrf = _csrf(client)
    for dest in ("/etc/passwd", "/mnt/../etc", "/tmp/usb", "relative", "/mnt"):
        response = client.post(
            "/backup/archives/tinyweb-20260101-000000/copy",
            headers=PARENT,
            data={"csrf": csrf, "destination": dest},
        )
        assert response.status_code == 400, dest
    assert "copy-archive" not in backup_env["log"].read_text(encoding="utf-8")


def test_schedule_defaults_and_validation(backup_env):
    client = backup_env["client"]
    bad = client.post(
        "/backup/settings",
        headers=PARENT,
        data={
            "csrf": _csrf(client),
            "frequency": "daily",
            "hour": "99",
            "minute": "0",
            "weekday": "0",
            "keep_last": "3",
            "max_age_days": "90",
            "min_free_gb": "2",
        },
    )
    assert bad.status_code == 400
    assert not backup_env["settings"].exists()
    saved = client.post(
        "/backup/settings",
        headers=PARENT,
        data={
            "csrf": _csrf(client),
            "frequency": "off",
            "hour": "3",
            "minute": "15",
            "weekday": "6",
            "keep_last": "3",
            "max_age_days": "90",
            "min_free_gb": "2",
        },
        follow_redirects=False,
    )
    assert saved.status_code == 303
    stored = json.loads(backup_env["settings"].read_text(encoding="utf-8"))
    assert stored["frequency"] == "off"
    assert "apply-schedule" in backup_env["log"].read_text(encoding="utf-8")
    assert default_settings().frequency == "off"


def test_retention_keeps_newest_and_ignores_foreign_names():
    now = datetime(2026, 1, 10, tzinfo=timezone.utc)
    records = [
        ArchiveRecord("tinyweb-20260101-000000", now - timedelta(days=9)),
        ArchiveRecord("tinyweb-20260108-000000", now - timedelta(days=2)),
        ArchiveRecord("tinyweb-20260109-000000", now - timedelta(days=1)),
        ArchiveRecord("manual-backup", now - timedelta(days=1)),
        ArchiveRecord("tinyweb-../../etc", now - timedelta(days=1)),
        ArchiveRecord("tinyweb-20251101-000000", now - timedelta(days=70)),
    ]
    doomed = retention_ids(records, Settings(keep_last=2, max_age_days=30), now)
    assert doomed == ["tinyweb-20251101-000000", "tinyweb-20260101-000000"]
    assert "manual-backup" not in doomed
    many = [
        ArchiveRecord(f"tinyweb-20260101-{index:06d}", now - timedelta(minutes=index))
        for index in range(40)
    ]
    # index 0 is newest because minutes=0. keep 1, so 39 doomed, capped at 20 oldest.
    capped = retention_ids(many, Settings(keep_last=1, max_age_days=0), now)
    assert len(capped) == 20
    assert capped[0] == "tinyweb-20260101-000039"
    only = retention_ids(
        [ArchiveRecord("tinyweb-20240101-000000", now - timedelta(days=800))],
        Settings(keep_last=3, max_age_days=30),
        now,
    )
    assert only == []


def test_archive_symlink_is_not_a_deletable_file(tmp_path):
    archives = tmp_path / "archives"
    archives.mkdir()
    real = tmp_path / "important.txt"
    real.write_text("keep", encoding="utf-8")
    link = archives / "tinyweb-20260101-000000.tar"
    link.symlink_to(real)
    assert archive_file_ok(archives, "tinyweb-20260101-000000") is False
    normal = archives / "tinyweb-20260102-000000.tar"
    normal.write_bytes(b"tar")
    assert archive_file_ok(archives, "tinyweb-20260102-000000") is True
    assert real.read_text(encoding="utf-8") == "keep"


def test_targets_exclude_media_and_command_is_argv_only():
    installed = {"synapse", "nextcloud", "mobilizon", "owntracks", "jellyfin", "immich", "element"}
    parts = {
        "conf_ldap",
        "conf_ynh_settings",
        "conf_ynh_certs",
        "conf_tinywebstack",
        "data_multimedia",
        "data_home",
        "data_mail",
    }
    selection = select_targets(installed, parts)
    assert "jellyfin" not in selection.apps
    assert "immich" not in selection.apps
    assert "data_multimedia" not in selection.system_parts
    assert "data_home" not in selection.system_parts
    command = build_create_command("tinyweb-20260101-000000", selection)
    assert command[0] == "yunohost"
    assert "jellyfin" not in command
    assert "data_multimedia" not in command
    assert "--apps" in command and "--system" in command
    assert all(isinstance(part, str) and " " not in part for part in command if part != "TinyWeb family backup")
    with pytest.raises(BackupError):
        build_create_command(
            "tinyweb-20260101-000000",
            TargetSelection(apps=["jellyfin"], system_parts=["conf_ldap", "data_multimedia"]),
        )
    with pytest.raises(BackupError):
        build_create_command("tinyweb-1;rm", selection)
    assert build_delete_command("tinyweb-20260101-000000") == [
        "yunohost",
        "backup",
        "delete",
        "tinyweb-20260101-000000",
    ]
    with pytest.raises(BackupError):
        select_targets({"synapse"}, {"conf_ldap", "conf_ynh_settings"})


def test_execute_backup_reports_failure_and_skips_low_space(tmp_path, monkeypatch):
    monkeypatch.setenv("TWS_BACKUP_SETTINGS_PATH", str(tmp_path / "settings.json"))
    state = tmp_path / "state"
    archives = tmp_path / "archives"
    archives.mkdir()
    conn = connect(state)
    job = insert_job(conn, kind="backup", actor="parent1")
    calls = []

    def fail(argv):
        calls.append(list(argv))
        return 1, "password=hunter2"

    code = execute_backup_job(
        conn,
        job["id"],
        installed={"synapse", "nextcloud", "jellyfin"},
        parts={"conf_ldap", "conf_ynh_settings", "conf_tinywebstack", "data_multimedia"},
        free_bytes=10,
        run=fail,
        archive_directory=archives,
        lock_fd=object(),
    )
    assert code == 1
    assert calls == []
    failed = conn.execute("SELECT detail, status FROM jobs WHERE id = ?", (job["id"],)).fetchone()
    assert failed["status"] == "failed"
    assert "hunter2" not in failed["detail"]
    assert "free" in failed["detail"].lower()

    job2 = insert_job(conn, kind="backup", actor="parent1")

    def boom(argv):
        calls.append(list(argv))
        return 1, "token=tws_abcdef Bearer hunter2"

    code = execute_backup_job(
        conn,
        job2["id"],
        installed={"synapse"},
        parts={"conf_ldap", "conf_ynh_settings", "conf_tinywebstack"},
        free_bytes=5 * 1024 * 1024 * 1024,
        run=boom,
        archive_directory=archives,
        lock_fd=object(),
    )
    assert code == 1
    assert calls and calls[-1][0] == "yunohost" and "jellyfin" not in calls[-1]
    detail = conn.execute("SELECT detail FROM jobs WHERE id = ?", (job2["id"],)).fetchone()["detail"]
    assert "hunter2" not in detail
    assert "tws_abcdef" not in detail
    assert not any(item[2] == "delete" for item in calls if len(item) > 2)
    conn.close()


def test_missing_hook_marker_fails_the_job(tmp_path, monkeypatch):
    monkeypatch.setenv("TWS_BACKUP_SETTINGS_PATH", str(tmp_path / "settings.json"))
    archives = tmp_path / "archives"
    archives.mkdir()
    conn = connect(tmp_path / "state")
    job = insert_job(conn, kind="backup", actor="parent1")
    calls = []

    def run(argv):
        argv = list(argv)
        calls.append(argv)
        if argv[2] == "create":
            name = argv[argv.index("--name") + 1]
            _write_archive(archives / f"{name}.tar", with_marker=False)
            return 0, ""
        if argv[2] == "delete":
            return 0, ""
        return 1, "no"

    code = execute_backup_job(
        conn,
        job["id"],
        installed={"synapse"},
        parts={"conf_ldap", "conf_ynh_settings", "conf_tinywebstack"},
        free_bytes=5 * 1024 * 1024 * 1024,
        run=run,
        archive_directory=archives,
        lock_fd=object(),
    )
    assert code == 1
    detail = conn.execute("SELECT status, detail FROM jobs WHERE id = ?", (job["id"],)).fetchone()
    assert detail["status"] == "failed"
    assert "TinyWeb" in detail["detail"]
    assert any(item[2] == "delete" for item in calls)
    conn.close()


def test_execute_backup_retention_skips_symlink(tmp_path, monkeypatch):
    monkeypatch.setenv("TWS_BACKUP_SETTINGS_PATH", str(tmp_path / "settings.json"))
    from tinywebstack_dashboard.backup import save_settings

    save_settings(Settings(keep_last=1, max_age_days=0, min_free_bytes=1024 * 1024 * 1024), tmp_path / "settings.json")
    state = tmp_path / "state"
    archives = tmp_path / "archives"
    archives.mkdir()
    important = tmp_path / "important.txt"
    important.write_text("keep", encoding="utf-8")
    link = archives / "tinyweb-20260101-000000.tar"
    link.symlink_to(important)
    normal_old = archives / "tinyweb-20260102-000000.tar"
    normal_old.write_bytes(b"old")
    conn = connect(state)
    old_link = insert_job(conn, kind="backup", actor="parent1", archive_id="tinyweb-20260101-000000")
    update_job(conn, old_link["id"], status="succeeded", archive_id="tinyweb-20260101-000000")
    old_file = insert_job(conn, kind="backup", actor="parent1", archive_id="tinyweb-20260102-000000")
    update_job(conn, old_file["id"], status="succeeded", archive_id="tinyweb-20260102-000000")
    job = insert_job(conn, kind="backup", actor="parent1")
    deleted = []

    def run(argv):
        argv = list(argv)
        if argv[2] == "create":
            name = argv[argv.index("--name") + 1]
            _write_archive(archives / f"{name}.tar", with_marker=True)
            return 0, ""
        if argv[2] == "delete":
            deleted.append(argv[3])
            target = archives / f"{argv[3]}.tar"
            if target.is_file() and not target.is_symlink():
                target.unlink()
            return 0, ""
        return 1, "no"

    code = execute_backup_job(
        conn,
        job["id"],
        installed={"synapse", "nextcloud", "mobilizon", "owntracks"},
        parts={"conf_ldap", "conf_ynh_settings", "conf_tinywebstack"},
        free_bytes=5 * 1024 * 1024 * 1024,
        run=run,
        archive_directory=archives,
        lock_fd=object(),
    )
    assert code == 0
    assert "tinyweb-20260101-000000" not in deleted
    assert "tinyweb-20260102-000000" in deleted
    assert important.read_text(encoding="utf-8") == "keep"
    assert link.is_symlink()
    conn.close()


def test_schedule_units_are_fixed_text(tmp_path):
    calls = []

    def run(argv):
        calls.append(list(argv))
        return 0

    apply_schedule(Settings(frequency="off"), unit_dir=tmp_path, run=run)
    assert calls == [["systemctl", "disable", "--now", TIMER_NAME]]
    calls.clear()
    settings = Settings(frequency="weekly", hour=3, minute=15, weekday=6)
    apply_schedule(settings, unit_dir=tmp_path, run=run)
    assert ["systemctl", "enable", "--now", TIMER_NAME] in calls
    text = (tmp_path / TIMER_NAME).read_text(encoding="utf-8")
    assert "OnCalendar=Sun *-*-* 03:15:00" in text
    assert "Persistent=false" in text
    assert ";" not in text
    assert "$" not in text
    assert on_calendar(settings) == "Sun *-*-* 03:15:00"
    units = render_systemd_units(settings)
    assert "ExecStart=/usr/local/sbin/tws-family-backup-privileged run-scheduled" in units[
        "tinywebstack-family-backup.service"
    ]
    with pytest.raises(BackupError):
        validate_settings({"frequency": "hourly", "hour": 1, "minute": 1, "weekday": 1, "keep_last": 1, "max_age_days": 1, "min_free_gb": 2})


def test_reconcile_marks_dead_worker_failed(tmp_path):
    conn = connect(tmp_path / "state")
    job = insert_job(conn, kind="backup", actor="parent1")
    update_job(conn, job["id"], status="running", phase="backup", pid=2**31 - 1, started_at=_iso(datetime.now(timezone.utc)))
    reconcile_jobs(conn)
    row = conn.execute("SELECT status, detail FROM jobs WHERE id = ?", (job["id"],)).fetchone()
    assert row["status"] == "failed"
    assert "restart" in row["detail"].lower()
    conn.close()


def test_sqlite_hook_snapshots_and_restore_paths(tmp_path, monkeypatch):
    monkeypatch.setenv("TWS_BACKUP_HOOK_ALLOW_NON_ROOT", "1")
    state = tmp_path / "etc" / "tinywebstack"
    state.mkdir(parents=True)
    db = state / "permissions.db"
    conn = sqlite3.connect(db)
    conn.execute("CREATE TABLE rules (v INTEGER)")
    conn.execute("INSERT INTO rules VALUES (1)")
    conn.commit()
    devices = state / "app-devices.db"
    dev = sqlite3.connect(devices)
    dev.execute("CREATE TABLE devices (id TEXT)")
    dev.execute("INSERT INTO devices VALUES ('phone')")
    dev.commit()
    dev.close()
    (state / "family-policy.json").write_text('{"kids":{}}\n', encoding="utf-8")
    outside = tmp_path / "outside.txt"
    outside.write_text("secret-password=hunter2\n", encoding="utf-8")
    (state / "dashboard.env").symlink_to(outside)
    layout = HookLayout(
        state_dir=state,
        permissions_db=db,
        app_devices_db=devices,
        synapse_conf_d=tmp_path / "no-synapse",
        nginx_conf_d=tmp_path / "no-nginx",
        hook_backup=tmp_path / "no-hook-a",
        hook_restore=tmp_path / "no-hook-b",
    )
    work = tmp_path / "work" / "conf" / "tinywebstack"
    skipped = snapshot_state(work, layout)
    assert "hunter2" not in json.dumps(skipped)
    assert not any("hunter2" in path.read_text(encoding="utf-8", errors="replace") for path in work.rglob("*") if path.is_file())
    (state / "dashboard.env").unlink()
    (state / "dashboard.env").write_text("TWS_SERVER_NAME=example\n", encoding="utf-8")
    conn.close()
    manifest = snapshot_state(work, layout)
    assert manifest["sqlite_method"] == "backup_api"
    assert "permissions.db" in manifest["snapshots"]
    again = sqlite3.connect(db)
    again.execute("INSERT INTO rules VALUES (2)")
    again.commit()
    again.close()
    snap = sqlite3.connect(work / "snapshots" / "permissions.db")
    assert [row[0] for row in snap.execute("SELECT v FROM rules")] == [1]
    snap.close()
    assert "hunter2" not in (work / "manifest.json").read_text(encoding="utf-8")
    copied = (work / "files" / "etc" / "tinywebstack" / "family-policy.json").read_text(encoding="utf-8")
    assert "kids" in copied

    dest = tmp_path / "restored"
    restore_state(work, layout, dest_root=dest)
    restored = sqlite3.connect(dest / "etc" / "tinywebstack" / "permissions.db")
    assert [row[0] for row in restored.execute("SELECT v FROM rules")] == [1]
    restored.close()
    assert (dest / "etc" / "tinywebstack" / "family-policy.json").is_file()
    (dest / "etc" / "tinywebstack" / "keep-me.txt").write_text("stay", encoding="utf-8")
    with pytest.raises(BackupError):
        restore_destination("../../etc/passwd", dest)
    with pytest.raises(BackupError):
        restore_destination("etc/nginx/conf.d/default.conf", dest)
    with pytest.raises(BackupError):
        restore_destination("/etc/tinywebstack/family-policy.json", dest)
    bad = json.loads((work / "manifest.json").read_text(encoding="utf-8"))
    bad["files"] = ["../../evil.txt"]
    (work / "manifest.json").write_text(json.dumps(bad), encoding="utf-8")
    with pytest.raises(BackupError):
        restore_state(work, layout, dest_root=dest)
    assert (dest / "etc" / "tinywebstack" / "keep-me.txt").read_text(encoding="utf-8") == "stay"
    assert not (tmp_path / "evil.txt").exists()


def test_hook_and_cli_refuse_unprivileged_call():
    env = os.environ.copy()
    env.pop("TWS_BACKUP_HOOK_ALLOW_NON_ROOT", None)
    env.pop("TWS_PRIVILEGED_ALLOW_NON_ROOT", None)
    env["PYTHONPATH"] = str(REPO / "family" / "dashboard")
    hook = subprocess.run(
        [sys.executable, "-m", "tinywebstack_dashboard.backup_hook", "restore", "/tmp/conf/tinywebstack"],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    assert hook.returncode != 0
    cli = subprocess.run(
        [sys.executable, "-m", "tinywebstack_dashboard.backup_cli", "run-backup", "../x"],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    assert cli.returncode != 0
    assert "hunter2" not in (hook.stderr + cli.stderr)


def test_export_and_redact_and_archive_name():
    assert validate_export_path("/mnt/usb/backups") == "/mnt/usb/backups"
    with pytest.raises(BackupError):
        validate_export_path("/var/backups")
    assert "hunter2" not in redact("password=hunter2")
    assert "tws_abc" not in redact("token tws_abc")
    assert new_archive_id(datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)) == "tinyweb-20260102-030405"
    titles = {row["title"] for row in coverage_rows()}
    assert "Family logins" in titles
    assert "Movies, shows, and photo libraries" in titles


def test_load_settings_rejects_garbage(tmp_path):
    path = tmp_path / "backup-settings.json"
    path.write_text("{", encoding="utf-8")
    assert load_settings(path).frequency == "off"
    path.write_text(json.dumps({"frequency": "daily", "hour": 3, "minute": 0, "weekday": 0, "keep_last": 2, "max_age_days": 10, "min_free_gb": 2}), encoding="utf-8")
    assert load_settings(path).frequency == "daily"
