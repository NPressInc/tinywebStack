"""Root-only backup commands used by the narrow sudo helper.

The dashboard never calls ``yunohost`` itself. It starts this module, which
accepts only fixed subcommands and passes list arguments (no shell).
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import Callable, List, Optional, Sequence

from tinywebstack_dashboard.backup import (
    HARD_MIN_FREE_BYTES,
    ArchiveRecord,
    BackupError,
    active_job,
    archive_dir,
    archive_file_ok,
    build_create_command,
    build_delete_command,
    connect,
    get_job,
    human_bytes,
    insert_job,
    job_lock,
    load_settings,
    managed_archive_records,
    new_archive_id,
    open_export_dir,
    redact,
    require_archive_id,
    require_job_id,
    retention_ids,
    same_archive_inode,
    select_targets,
    space_ok,
    state_dir,
    archive_inode,
    inspect_archive,
    update_job,
    utcnow,
    describe_space,
)
from tinywebstack_dashboard.backup import HOOK_FILES, apply_schedule

Run = Callable[[Sequence[str]], "tuple[int, str]"]


def require_priv() -> None:
    if os.environ.get("TWS_PRIVILEGED_ALLOW_NON_ROOT") == "1":
        return
    if os.geteuid() != 0:
        raise SystemExit("Run as root")


def run_command(argv: Sequence[str]) -> tuple[int, str]:
    if not argv or argv[0] not in {"yunohost", "systemctl"}:
        raise BackupError("Refusing to run that command.")
    proc = subprocess.run(
        list(argv),
        check=False,
        capture_output=True,
        text=True,
    )
    err = (proc.stderr or "") + ("\n" + proc.stdout if proc.returncode else "")
    return proc.returncode, err


def present_parts() -> set[str]:
    return {part for part, path in HOOK_FILES.items() if Path(path).is_file()}


def _yunohost_json(argv: Sequence[str]) -> dict:
    proc = subprocess.run(list(argv), check=False, capture_output=True, text=True)
    if proc.returncode != 0:
        raise BackupError(redact(proc.stderr or "Could not list installed apps."))
    try:
        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise BackupError("Could not read the list of installed apps.") from exc
    if not isinstance(data, dict):
        return {}
    return data


def detect_installed_apps() -> set[str]:
    data = _yunohost_json(["yunohost", "app", "list", "--output-as", "json"])
    apps = data.get("apps", data)
    found: set[str] = set()
    if isinstance(apps, dict):
        found.update(str(key) for key in apps.keys())
    elif isinstance(apps, list):
        for item in apps:
            if isinstance(item, str):
                found.add(item)
            elif isinstance(item, dict) and item.get("id"):
                found.add(str(item["id"]))
    return found


def disk_free(path: Path) -> int:
    target = path if path.is_dir() else path.parent
    if not target.is_dir():
        target = Path("/")
    return shutil.disk_usage(target).free


def nextcloud_data_bytes() -> Optional[int]:
    """Best-effort size of the Nextcloud data folder. None when it cannot be measured."""
    candidates: List[Path] = []
    try:
        proc = subprocess.run(
            ["yunohost", "app", "setting", "nextcloud", "data_dir"],
            check=False,
            capture_output=True,
            text=True,
            timeout=8,
        )
    except (OSError, subprocess.TimeoutExpired):
        proc = None
    if proc is not None and proc.returncode == 0:
        text = (proc.stdout or "").strip()
        path = Path(text)
        if text.startswith("/") and ".." not in path.parts and "\n" not in text:
            candidates.append(path)
    candidates.extend(
        [
            Path("/home/yunohost.app/nextcloud/data"),
            Path("/var/www/nextcloud/data"),
        ]
    )
    for cand in candidates:
        try:
            if cand.is_symlink() or not cand.is_dir():
                continue
            measured = subprocess.run(
                ["du", "-sb", str(cand)],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if measured.returncode != 0:
            continue
        token = (measured.stdout or "").split()
        if token and token[0].isdigit():
            return int(token[0])
    return None


def preflight_payload() -> dict:
    settings = load_settings()
    directory = archive_dir()
    free = disk_free(directory)
    needed = max(settings.min_free_bytes, HARD_MIN_FREE_BYTES)
    nextcloud_bytes = nextcloud_data_bytes()
    described = describe_space(free, needed, nextcloud_bytes)
    return {
        "free_bytes": free,
        "archive_dir": str(directory),
        "min_free_bytes": needed,
        "ok": described["ok"],
        "nextcloud_bytes": nextcloud_bytes,
        "size_note": described["size_note"],
    }


def fail_job(conn, job_id: str, detail: str) -> None:
    update_job(
        conn,
        job_id,
        status="failed",
        phase="failed",
        finished_at=utcnow().isoformat(),
        detail=redact(detail),
        pid=None,
    )


def execute_backup_job(
    conn,
    job_id: str,
    *,
    installed: set[str],
    parts: set[str],
    free_bytes: int,
    run: Run,
    archive_directory: Path,
    lock_fd: object,
) -> int:
    """Run one backup. ``lock_fd`` is held by the caller for the whole call."""
    del lock_fd  # presence means the caller holds the lock
    require_job_id(job_id)
    settings = load_settings()
    update_job(
        conn,
        job_id,
        status="running",
        phase="preflight",
        pid=os.getpid(),
        started_at=utcnow().isoformat(),
    )
    if not space_ok(free_bytes, settings):
        fail_job(
            conn,
            job_id,
            "Not enough free disk space. "
            f"{human_bytes(free_bytes)} is free and this backup needs "
            f"{human_bytes(max(settings.min_free_bytes, HARD_MIN_FREE_BYTES))} free.",
        )
        return 1
    try:
        selection = select_targets(installed, parts)
    except BackupError as exc:
        fail_job(conn, job_id, str(exc))
        return 1
    archive_id = new_archive_id()
    summary = json.dumps(
        {"apps": selection.apps, "system": selection.system_parts, "notes": selection.notes}
    )
    update_job(conn, job_id, phase="backup", archive_id=archive_id, summary=summary)
    code, err = run(build_create_command(archive_id, selection))
    if code != 0:
        fail_job(conn, job_id, err or "Backup command failed.")
        return 1
    if not archive_file_ok(archive_directory, archive_id):
        fail_job(conn, job_id, "The backup command finished but the archive file is missing.")
        return 1
    archive_path = archive_directory / f"{archive_id}.tar"
    viewed = inspect_archive(archive_path)
    if viewed is None:
        fail_job(conn, job_id, "The backup command finished but the archive file is missing.")
        return 1
    dev, ino, size, has_marker = viewed
    if not has_marker:
        if not same_archive_inode(archive_path, (dev, ino, size)):
            fail_job(conn, job_id, "The archive changed before it could be checked. Nothing was deleted.")
            return 1
        run(build_delete_command(archive_id))
        fail_job(
            conn,
            job_id,
            "The backup command finished but TinyWeb's own data was not in the archive.",
        )
        return 1
    if not same_archive_inode(archive_path, (dev, ino, size)):
        fail_job(conn, job_id, "The archive changed before it could be checked. Nothing was deleted.")
        return 1
    update_job(conn, job_id, phase="retention")
    notes: List[str] = []
    records = managed_archive_records(conn)
    records.append(ArchiveRecord(archive_id=archive_id, created_at=utcnow()))
    doomed = retention_ids(records, settings)
    for old_id in doomed:
        if old_id == archive_id:
            continue
        path = archive_directory / f"{old_id}.tar"
        ident = archive_inode(path)
        if ident is None:
            notes.append(f"Left {old_id} in place because it is not a normal archive file.")
            continue
        if not same_archive_inode(path, ident):
            notes.append(f"Left {old_id} in place because it changed before it could be removed.")
            continue
        del_code, del_err = run(build_delete_command(old_id))
        if del_code != 0:
            notes.append(f"Could not remove old backup {old_id}.")
            if del_err:
                notes.append(redact(del_err, limit=120))
    detail = " ".join(notes)
    update_job(
        conn,
        job_id,
        status="succeeded",
        phase="succeeded",
        finished_at=utcnow().isoformat(),
        detail=detail,
        pid=None,
    )
    return 0


def _unlink_partial(dir_fd: Optional[int], name: Optional[str]) -> None:
    if dir_fd is None or not name:
        return
    try:
        st = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError:
        return
    if not stat.S_ISREG(st.st_mode):
        return
    try:
        os.unlink(name, dir_fd=dir_fd)
    except OSError:
        return


def execute_copy_job(conn, job_id: str, archive_directory: Path) -> int:
    require_job_id(job_id)
    job = get_job(conn, job_id)
    update_job(
        conn,
        job_id,
        status="running",
        phase="copy",
        pid=os.getpid(),
        started_at=utcnow().isoformat(),
    )
    dir_fd: Optional[int] = None
    partial_name: Optional[str] = None
    try:
        archive_id = require_archive_id(job.get("archive_id") or "")
        src = archive_directory / f"{archive_id}.tar"
        src_ident = archive_inode(src)
        if src_ident is None:
            raise BackupError("That backup is not a file this page can copy.")
        dir_fd = open_export_dir(job.get("export_path") or "")
        vfs = os.fstatvfs(dir_fd)
        free = vfs.f_bavail * vfs.f_frsize
        src_fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            src_st = os.fstat(src_fd)
            if (src_st.st_dev, src_st.st_ino, src_st.st_size) != src_ident:
                raise BackupError("The archive changed before it could be copied.")
            if free < src_st.st_size + HARD_MIN_FREE_BYTES:
                raise BackupError(
                    "Not enough free space on that disk. "
                    f"The backup is {human_bytes(src_st.st_size)} and {human_bytes(free)} is free."
                )
            partial_name = "." + archive_id + ".tar.partial"
            final_name = archive_id + ".tar"
            try:
                os.stat(final_name, dir_fd=dir_fd, follow_symlinks=False)
                raise BackupError("A file with that name is already in the folder.")
            except FileNotFoundError:
                pass
            dst_fd = os.open(
                partial_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=dir_fd,
            )
            try:
                while True:
                    chunk = os.read(src_fd, 1024 * 1024)
                    if not chunk:
                        break
                    os.write(dst_fd, chunk)
            finally:
                os.close(dst_fd)
        finally:
            os.close(src_fd)
        if not stat.S_ISDIR(os.fstat(dir_fd).st_mode):
            raise BackupError("That folder is no longer a directory.")
        os.replace(partial_name, final_name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        partial_name = None
    except BackupError as exc:
        _unlink_partial(dir_fd, partial_name)
        fail_job(conn, job_id, str(exc))
        return 1
    except OSError as exc:
        _unlink_partial(dir_fd, partial_name)
        fail_job(conn, job_id, f"Could not copy the backup ({exc.errno}).")
        return 1
    finally:
        if dir_fd is not None:
            os.close(dir_fd)
    update_job(
        conn,
        job_id,
        status="succeeded",
        phase="succeeded",
        finished_at=utcnow().isoformat(),
        detail="Copied off this box.",
        pid=None,
    )
    return 0


def stream_archive(archive_id: str, out) -> None:
    require_archive_id(archive_id)
    conn = connect()
    try:
        known = {
            record.archive_id
            for record in managed_archive_records(conn)
        }
    finally:
        conn.close()
    if archive_id not in known:
        raise BackupError("Unknown backup.")
    directory = archive_dir()
    if not archive_file_ok(directory, archive_id):
        raise BackupError("That backup is not a file this page can download.")
    path = directory / f"{archive_id}.tar"
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
            out.flush()
    finally:
        os.close(fd)


def list_archives_payload() -> dict:
    conn = connect()
    try:
        directory = archive_dir()
        archives = []
        seen = set()
        for record in managed_archive_records(conn):
            if record.archive_id in seen:
                continue
            seen.add(record.archive_id)
            if not archive_file_ok(directory, record.archive_id):
                continue
            path = directory / f"{record.archive_id}.tar"
            archives.append({"id": record.archive_id, "bytes": path.stat().st_size})
        return {"archives": archives}
    finally:
        conn.close()


def _with_lock(conn, job_id: str, body: Callable[[], int]) -> int:
    fd = job_lock(state_dir())
    if fd is None:
        fail_job(conn, job_id, "Another backup is already running.")
        return 1
    try:
        return body()
    except BackupError as exc:
        fail_job(conn, job_id, str(exc))
        return 1
    except Exception:
        fail_job(conn, job_id, "Backup failed.")
        return 1
    finally:
        os.close(fd)


def run_backup(job_id: str) -> int:
    require_job_id(job_id)
    conn = connect()
    try:
        get_job(conn, job_id)

        def body() -> int:
            return execute_backup_job(
                conn,
                job_id,
                installed=detect_installed_apps(),
                parts=present_parts(),
                free_bytes=disk_free(archive_dir()),
                run=run_command,
                archive_directory=archive_dir(),
                lock_fd=None,
            )

        return _with_lock(conn, job_id, body)
    finally:
        conn.close()


def run_copy(job_id: str) -> int:
    require_job_id(job_id)
    conn = connect()
    try:
        get_job(conn, job_id)

        def body() -> int:
            return execute_copy_job(conn, job_id, archive_dir())

        return _with_lock(conn, job_id, body)
    finally:
        conn.close()


def run_scheduled() -> int:
    settings = load_settings()
    if settings.frequency == "off":
        return 0
    conn = connect()
    try:
        if active_job(conn):
            return 0
        job = insert_job(conn, kind="backup", actor="schedule")
    finally:
        conn.close()
    return run_backup(job["id"])


def run_apply_schedule() -> int:
    settings = load_settings()
    unit_dir = Path(os.environ.get("TWS_BACKUP_SYSTEMD_DIR", "/etc/systemd/system"))

    def run(argv: Sequence[str]) -> int:
        code, _err = run_command(argv)
        return code

    try:
        apply_schedule(settings, unit_dir=unit_dir, run=run)
    except BackupError as exc:
        print(redact(str(exc)), file=sys.stderr)
        return 1
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    require_priv()
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        print("missing command", file=sys.stderr)
        return 1
    cmd, rest = args[0], args[1:]
    try:
        if cmd == "preflight" and not rest:
            json.dump(preflight_payload(), sys.stdout)
            sys.stdout.write("\n")
            return 0
        if cmd == "list-archives" and not rest:
            json.dump(list_archives_payload(), sys.stdout)
            sys.stdout.write("\n")
            return 0
        if cmd == "run-backup" and len(rest) == 1:
            return run_backup(require_job_id(rest[0]))
        if cmd == "run-scheduled" and not rest:
            return run_scheduled()
        if cmd == "cat-archive" and len(rest) == 1:
            stream_archive(require_archive_id(rest[0]), sys.stdout.buffer)
            return 0
        if cmd == "copy-archive" and len(rest) == 1:
            return run_copy(require_job_id(rest[0]))
        if cmd == "apply-schedule" and not rest:
            return run_apply_schedule()
    except BackupError as exc:
        print(redact(str(exc)), file=sys.stderr)
        return 1
    except SystemExit:
        raise
    print("unknown command", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
