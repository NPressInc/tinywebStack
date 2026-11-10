"""Stdlib-only restore of TinyWeb state.

A replacement computer runs this file with system ``python3`` before the
dashboard virtualenv exists. The backup hook copies this file into the archive
as ``tinyweb_restore.py``. Do not import the dashboard package from here.
"""

from __future__ import annotations

import json
import os
import sqlite3
import stat
import sys
from pathlib import Path
from typing import Optional, Tuple

MAX_CONFIG_BYTES = 2 * 1024 * 1024

EXACT_RELS = frozenset(
    {
        "etc/yunohost/hooks.d/backup/99-conf_tinywebstack",
        "etc/yunohost/hooks.d/restore/99-conf_tinywebstack",
    }
)
SQLITE_NAMES = frozenset({"permissions.db", "app-devices.db"})


class RestoreError(Exception):
    """A restore path or snapshot was refused."""


def lexical_rel(rel: str) -> str:
    """Allowlist of archive paths. This does not look at the filesystem."""
    if not isinstance(rel, str) or not rel or "\\" in rel or "\x00" in rel or rel.startswith("/"):
        raise RestoreError("Refusing a backup path.")
    parts = rel.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise RestoreError("Refusing a backup path.")
    text = "/".join(parts)
    if text in EXACT_RELS:
        return text
    if text.startswith("etc/tinywebstack/"):
        return text
    if text.startswith("etc/matrix-synapse/conf.d/"):
        if len(parts) == 4 and parts[-1].startswith("tinywebstack"):
            return text
        raise RestoreError("Refusing a Synapse file that is not a TinyWeb snippet.")
    if text.startswith("etc/nginx/conf.d/"):
        if "tinywebstack" not in parts[-1]:
            raise RestoreError("Refusing a nginx file that is not a TinyWeb snippet.")
        if len(parts) == 4 or (len(parts) == 5 and parts[3].endswith(".d")):
            return text
        raise RestoreError("Refusing a nginx path.")
    raise RestoreError("Refusing a file this hook does not restore.")


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        wrote = os.write(fd, view)
        if wrote <= 0:
            raise RestoreError("Could not write the restored file.")
        view = view[wrote:]


def open_root(root: Path) -> int:
    if not root.is_absolute():
        raise RestoreError("Restore root must be absolute.")
    try:
        return os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as exc:
        raise RestoreError("Restore root is not a real directory.") from exc


def open_parent_nofollow(root: Path, rel: str) -> Tuple[int, str]:
    """Walk ``rel`` under ``root`` with openat. Refuse a symlink in any component."""
    text = lexical_rel(rel)
    parts = text.split("/")
    dir_fd = open_root(root)
    try:
        for part in parts[:-1]:
            try:
                st = os.stat(part, dir_fd=dir_fd, follow_symlinks=False)
            except FileNotFoundError:
                os.mkdir(part, mode=0o755, dir_fd=dir_fd)
                st = os.stat(part, dir_fd=dir_fd, follow_symlinks=False)
            if stat.S_ISLNK(st.st_mode):
                raise RestoreError("Refusing a symlink in the restore path.")
            if not stat.S_ISDIR(st.st_mode):
                raise RestoreError("Restore path is not a directory.")
            try:
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)
            except OSError as exc:
                raise RestoreError("Refusing a symlink in the restore path.") from exc
            os.close(dir_fd)
            dir_fd = next_fd
        final = parts[-1]
        try:
            st_final = os.stat(final, dir_fd=dir_fd, follow_symlinks=False)
        except FileNotFoundError:
            st_final = None
        if st_final is not None and stat.S_ISLNK(st_final.st_mode):
            raise RestoreError("Refusing a symlink in the restore path.")
        return dir_fd, final
    except Exception:
        os.close(dir_fd)
        raise


def atomic_write_at(dir_fd: int, name: str, data: bytes, mode: int = 0o640) -> None:
    tmp = "." + name + ".restore-tmp"
    try:
        st = os.stat(tmp, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        st = None
    if st is not None:
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
            raise RestoreError("Refusing to replace a link.")
        os.unlink(tmp, dir_fd=dir_fd)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=dir_fd)
    try:
        _write_all(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)


def restore_destination(rel: str, root: Path) -> Path:
    """Return the lexical destination after proving no component is a symlink."""
    text = lexical_rel(rel)
    dir_fd, _final = open_parent_nofollow(root, text)
    os.close(dir_fd)
    return root.joinpath(*text.split("/"))


def write_restore_file(rel: str, root: Path, data: bytes) -> None:
    if len(data) > MAX_CONFIG_BYTES:
        raise RestoreError("Refusing an oversized settings file.")
    dir_fd, name = open_parent_nofollow(root, rel)
    try:
        atomic_write_at(dir_fd, name, data)
    finally:
        os.close(dir_fd)


def read_regular_nofollow(path: Path) -> bytes:
    if not path.is_absolute():
        raise RestoreError("Refusing a relative snapshot path.")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as exc:
        raise RestoreError("A backed-up file is missing.") from exc
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise RestoreError("A backed-up file is not a regular file.")
        if st.st_size > MAX_CONFIG_BYTES:
            raise RestoreError("Refusing an oversized settings file.")
        return os.read(fd, MAX_CONFIG_BYTES + 1)
    finally:
        os.close(fd)


def snapshot_sqlite(src: Path, dest: Path) -> None:
    """Consistent snapshot. ``src`` must already be a regular file, not a link."""
    try:
        src_fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as exc:
        raise RestoreError("Database snapshot is missing.") from exc
    os.close(src_fd)
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.is_symlink():
        raise RestoreError("Refusing to write a snapshot onto a link.")
    if dest.exists():
        dest.unlink()
    source = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    try:
        target = sqlite3.connect(dest)
        try:
            with target:
                source.backup(target)
        finally:
            target.close()
    finally:
        source.close()


def restore_sqlite_file(snapshot: Path, rel: str, root: Path) -> None:
    dir_fd, name = open_parent_nofollow(root, rel)
    try:
        parent = root.joinpath(*lexical_rel(rel).split("/")[:-1])
        tmp = parent / ("." + name + ".restore-tmp")
        if tmp.is_symlink():
            raise RestoreError("Refusing to write a snapshot onto a link.")
        snapshot_sqlite(snapshot, tmp)
        os.replace(
            "." + name + ".restore-tmp",
            name,
            src_dir_fd=dir_fd,
            dst_dir_fd=dir_fd,
        )
    finally:
        os.close(dir_fd)


def _read_snapshot_path(backup_dir: Path, name: str) -> Path:
    if name not in SQLITE_NAMES:
        raise RestoreError("Refusing an unknown database snapshot.")
    path = backup_dir / "snapshots" / name
    if path.is_symlink() or not path.is_file():
        raise RestoreError("Database snapshot is missing.")
    return path


def restore_state(backup_dir: Path, dest_root: Path) -> None:
    if not dest_root.exists():
        dest_root.mkdir(parents=True, exist_ok=True)
    manifest_path = backup_dir / "manifest.json"
    try:
        if manifest_path.is_symlink():
            raise RestoreError("TinyWeb backup manifest is missing.")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RestoreError("TinyWeb backup manifest is missing.") from exc
    if not isinstance(manifest, dict) or manifest.get("sqlite_method") != "backup_api":
        raise RestoreError("TinyWeb backup was not made with a database snapshot.")
    for name in manifest.get("snapshots") or []:
        if not isinstance(name, str):
            raise RestoreError("Refusing an unknown database snapshot.")
        snap = _read_snapshot_path(backup_dir, name)
        restore_sqlite_file(snap, f"etc/tinywebstack/{name}", dest_root)
    for rel in manifest.get("files") or []:
        if not isinstance(rel, str):
            raise RestoreError("Refusing a backup path.")
        text = lexical_rel(rel)
        src = backup_dir / "files" / text
        data = read_regular_nofollow(src)
        write_restore_file(text, dest_root, data)


def dest_root_from_env() -> Path:
    raw = os.environ.get("TWS_RESTORE_DEST", "").strip()
    if not raw:
        return Path("/")
    path = Path(raw)
    if not path.is_absolute() or ".." in path.parts:
        raise RestoreError("TWS_RESTORE_DEST must be an absolute directory.")
    return path


def main(argv: Optional[list[str]] = None) -> int:
    if os.environ.get("TWS_BACKUP_HOOK_ALLOW_NON_ROOT") != "1" and os.geteuid() != 0:
        print("TinyWeb restore must run as root", file=sys.stderr)
        return 1
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2 or args[0] != "restore":
        print("Usage: tinyweb_restore.py restore WORK_DIR/conf/tinywebstack", file=sys.stderr)
        return 1
    try:
        restore_state(Path(args[1]), dest_root_from_env())
    except RestoreError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
