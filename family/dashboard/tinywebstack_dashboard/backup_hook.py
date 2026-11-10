"""YunoHost backup/restore hook body for TinyWeb state.

The shell hooks under scripts/hooks call ``python -m tinywebstack_dashboard.backup_hook``.
SQLite databases are snapshotted with the backup API into the YunoHost work
directory. YunoHost then packs that directory. Live database files are not
declared as archive sources.
"""

from __future__ import annotations

import json
import os
import stat
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

from tinywebstack_dashboard.backup import BackupError, restore_sqlite_snapshot, snapshot_sqlite

MAX_CONFIG_BYTES = 2 * 1024 * 1024

STATE_FILES = (
    "family-policy.json",
    "dashboard.env",
    "pending-invites.json",
    "owntracks-kids.json",
    "owntracks-recorder.htpasswd",
    "synapse-admin-token",
    "matrix-login-ticket.secret",
    "mobilizon-family.exs",
    "backup-settings.json",
    "lab-ca.pem",
)
SECRET_FILES = (
    "secrets/install.env",
    "secrets/mobilizon-admin.password",
    "secrets/synapse-admin.password",
)
SQLITE_NAMES = {
    "permissions.db": "permissions.db",
    "app-devices.db": "app-devices.db",
}


@dataclass
class HookLayout:
    state_dir: Path = Path("/etc/tinywebstack")
    permissions_db: Path = Path("/etc/tinywebstack/permissions.db")
    app_devices_db: Path = Path("/etc/tinywebstack/app-devices.db")
    synapse_conf_d: Path = Path("/etc/matrix-synapse/conf.d")
    nginx_conf_d: Path = Path("/etc/nginx/conf.d")
    hook_backup: Path = Path("/etc/yunohost/hooks.d/backup/99-conf_tinywebstack")
    hook_restore: Path = Path("/etc/yunohost/hooks.d/restore/99-conf_tinywebstack")
    extra_roots: tuple[Path, ...] = field(default_factory=tuple)

    def allowed_roots(self) -> List[Path]:
        roots = [self.state_dir, self.synapse_conf_d, self.nginx_conf_d, *self.extra_roots]
        return roots


def production_layout() -> HookLayout:
    return HookLayout()


def _under(path: Path, root: Path) -> bool:
    try:
        real = path.resolve()
        base = root.resolve()
    except OSError:
        return False
    return real == base or base in real.parents


def _read_regular(src: Path, root: Path) -> Optional[bytes]:
    """Read a small config file. Refuse symlinks that leave ``root``."""
    try:
        st = src.lstat()
    except OSError:
        return None
    open_path = src
    if stat.S_ISLNK(st.st_mode):
        if not _under(src, root):
            raise BackupError(f"Refusing a link outside {root}")
        open_path = src.resolve()
        if not _under(open_path, root) or not open_path.is_file():
            return None
        try:
            st = open_path.lstat()
        except OSError:
            return None
    if not stat.S_ISREG(st.st_mode):
        return None
    if st.st_size > MAX_CONFIG_BYTES:
        return None
    fd = os.open(open_path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        return os.read(fd, MAX_CONFIG_BYTES + 1)
    finally:
        os.close(fd)


def _rel_under_state(path: Path, layout: HookLayout) -> str:
    rel = path.resolve().relative_to(layout.state_dir.resolve()).as_posix()
    if rel.startswith("../") or rel == ".." or "/.." in f"/{rel}":
        raise BackupError("Refusing a settings path that leaves TinyWeb state.")
    return rel


def iter_config_sources(layout: HookLayout) -> List[Path]:
    found: List[Path] = []
    for name in (*STATE_FILES, *SECRET_FILES):
        path = layout.state_dir / name
        if path.is_file() and not path.is_symlink():
            found.append(path)
        elif path.is_symlink() and _under(path, layout.state_dir) and path.resolve().is_file():
            found.append(path)
    secrets = layout.state_dir / "secrets"
    if secrets.is_dir() and not secrets.is_symlink():
        for child in sorted(secrets.iterdir()):
            if child.name.startswith("."):
                continue
            if child.is_file() and not child.is_symlink():
                if child not in found:
                    found.append(child)
    for root, needle in (
        (layout.synapse_conf_d, "tinywebstack"),
        (layout.nginx_conf_d, "tinywebstack"),
    ):
        found.extend(_named_files(root, needle, depth=0, max_depth=2))
    for hook in (layout.hook_backup, layout.hook_restore):
        if hook.is_file() and not hook.is_symlink():
            found.append(hook)
    return found


def _named_files(root: Path, needle: str, depth: int, max_depth: int) -> List[Path]:
    if depth > max_depth or not root.is_dir() or root.is_symlink():
        return []
    found: List[Path] = []
    try:
        children = list(root.iterdir())
    except OSError:
        return []
    for child in children:
        try:
            if child.is_symlink():
                if not _under(child, root):
                    continue
            if child.is_file() and needle in child.name:
                found.append(child)
            elif child.is_dir() and not child.is_symlink():
                found.extend(_named_files(child, needle, depth + 1, max_depth))
        except OSError:
            continue
    return found


def _sqlite_sources(layout: HookLayout) -> Dict[str, Path]:
    return {
        "permissions.db": layout.permissions_db,
        "app-devices.db": layout.app_devices_db,
    }


def snapshot_state(backup_dir: Path, layout: Optional[HookLayout] = None) -> dict:
    """Write snapshots and config copies into the YunoHost work directory."""
    layout = layout or production_layout()
    backup_dir.mkdir(parents=True, exist_ok=True)
    snapshots = backup_dir / "snapshots"
    files_root = backup_dir / "files"
    manifest_snaps: List[str] = []
    missing: List[str] = []
    for name, src in _sqlite_sources(layout).items():
        if not src.is_file() or src.is_symlink():
            missing.append(name)
            continue
        snapshot_sqlite(src, snapshots / name)
        manifest_snaps.append(name)
    copied: List[str] = []
    skipped: List[str] = []
    for src in iter_config_sources(layout):
        rel = _archive_rel(src, layout)
        if rel is None:
            skipped.append(str(src))
            continue
        data = _read_regular(src, _root_for(src, layout))
        if data is None:
            skipped.append(rel)
            continue
        if len(data) > MAX_CONFIG_BYTES:
            skipped.append(rel)
            continue
        dest = files_root / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(dest.suffix + ".tmp")
        tmp.write_bytes(data)
        os.replace(tmp, dest)
        copied.append(rel)
    manifest = {
        "hook": "conf_tinywebstack",
        "sqlite_method": "backup_api",
        "snapshots": manifest_snaps,
        "snapshots_missing": missing,
        "files": copied,
        "files_skipped": skipped,
    }
    (backup_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


def _root_for(src: Path, layout: HookLayout) -> Path:
    for root in layout.allowed_roots():
        if _under(src, root):
            return root
    if _under(src, layout.hook_backup.parent) or _under(src, layout.hook_restore.parent):
        return src.parent
    raise BackupError("Refusing to read a file outside TinyWeb backup roots.")


def _archive_rel(src: Path, layout: HookLayout) -> Optional[str]:
    """Relative archive path. None when the file is not an allowed restore target."""
    try:
        if _under(src, layout.state_dir):
            return "etc/tinywebstack/" + _rel_under_state(src, layout)
        if _under(src, layout.synapse_conf_d) and "tinywebstack" in src.name:
            return "etc/matrix-synapse/conf.d/" + src.name
        if _under(src, layout.nginx_conf_d) and "tinywebstack" in src.name:
            rel = src.resolve().relative_to(layout.nginx_conf_d.resolve()).as_posix()
            if ".." in rel.split("/"):
                return None
            return "etc/nginx/conf.d/" + rel
        if src == layout.hook_backup:
            return "etc/yunohost/hooks.d/backup/99-conf_tinywebstack"
        if src == layout.hook_restore:
            return "etc/yunohost/hooks.d/restore/99-conf_tinywebstack"
    except (OSError, ValueError):
        return None
    return None


_RESTORE_PREFIXES = (
    "etc/tinywebstack/",
    "etc/matrix-synapse/conf.d/tinywebstack",
    "etc/nginx/conf.d/",
    "etc/yunohost/hooks.d/backup/99-conf_tinywebstack",
    "etc/yunohost/hooks.d/restore/99-conf_tinywebstack",
)


def restore_destination(rel: str, root: Path) -> Path:
    """Map a manifest path onto ``root``. Reject traversal and unexpected files."""
    if not rel or rel.startswith("/") or "\\" in rel:
        raise BackupError("Refusing a backup path.")
    parts = Path(rel).parts
    if ".." in parts or "." in parts:
        raise BackupError("Refusing a backup path.")
    text = Path(rel).as_posix()
    if text.startswith("etc/nginx/conf.d/") and "tinywebstack" not in Path(text).name:
        raise BackupError("Refusing a nginx file that is not a TinyWeb snippet.")
    if text.startswith("etc/matrix-synapse/conf.d/") and not Path(text).name.startswith(
        "tinywebstack"
    ):
        raise BackupError("Refusing a Synapse file that is not a TinyWeb snippet.")
    if not any(text.startswith(prefix) for prefix in _RESTORE_PREFIXES):
        raise BackupError("Refusing a file this hook does not restore.")
    dest = (root / text).resolve()
    base = root.resolve()
    if dest != base and base not in dest.parents:
        raise BackupError("Refusing a restore path that leaves the target root.")
    return dest


def restore_state(backup_dir: Path, layout: Optional[HookLayout] = None, *, dest_root: Optional[Path] = None) -> None:
    """Apply a hook snapshot. ``dest_root`` is ``/`` on a real restore."""
    layout = layout or production_layout()
    root = dest_root if dest_root is not None else Path("/")
    manifest_path = backup_dir / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BackupError("TinyWeb backup manifest is missing.") from exc
    if not isinstance(manifest, dict) or manifest.get("sqlite_method") != "backup_api":
        raise BackupError("TinyWeb backup was not made with a database snapshot.")
    for name in manifest.get("snapshots") or []:
        if name not in SQLITE_NAMES:
            raise BackupError("Refusing an unknown database snapshot.")
        snap = backup_dir / "snapshots" / name
        if dest_root is not None:
            live = dest_root / "etc/tinywebstack" / name
        elif name == "permissions.db":
            live = layout.permissions_db
        else:
            live = layout.app_devices_db
        restore_sqlite_snapshot(snap, live)
    for rel in manifest.get("files") or []:
        if not isinstance(rel, str):
            raise BackupError("Refusing a backup path.")
        src = backup_dir / "files" / rel
        if src.is_symlink() or not src.is_file():
            raise BackupError("A backed-up settings file is missing.")
        dest = restore_destination(rel, root)
        data = src.read_bytes()
        if len(data) > MAX_CONFIG_BYTES:
            raise BackupError("Refusing an oversized settings file.")
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(dest.suffix + ".tmp")
        tmp.write_bytes(data)
        os.replace(tmp, dest)


def assert_hook_dir(path: Path) -> Path:
    if not path.is_absolute() or ".." in path.parts:
        raise BackupError("Refusing the backup work directory.")
    if path.name != "tinywebstack" or path.parent.name != "conf":
        raise BackupError("Refusing the backup work directory.")
    real = path.resolve()
    allowed = [Path("/home/yunohost.backup")]
    extra = os.environ.get("TWS_BACKUP_HOOK_ROOT", "").strip()
    if extra:
        allowed.append(Path(extra).resolve())
    if not any(base == real or base in real.parents for base in allowed):
        raise BackupError("Refusing the backup work directory.")
    return real


def require_root() -> None:
    if os.environ.get("TWS_BACKUP_HOOK_ALLOW_NON_ROOT") == "1":
        return
    if os.geteuid() != 0:
        raise SystemExit("TinyWeb backup hook must run as root")


def main(argv: Optional[List[str]] = None) -> int:
    require_root()
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2 or args[0] not in {"snapshot", "restore"}:
        print("Usage: backup_hook.py snapshot|restore WORK_DIR/conf/tinywebstack", file=sys.stderr)
        return 1
    try:
        work = assert_hook_dir(Path(args[1]))
        if args[0] == "snapshot":
            snapshot_state(work)
        else:
            restore_state(work)
    except BackupError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
