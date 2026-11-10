"""Parent-dashboard backup policy on top of YunoHost's backup system.

YunoHost collects app files and database dumps, then packs them. This module
decides which apps and system parts a TinyWeb backup asks for, snapshots the
family SQLite databases, and tracks jobs. It does not invent a second archive
format and it never starts a restore.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import sqlite3
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

ARCHIVE_ID_RE = re.compile(r"^tinyweb-[0-9]{8}-[0-9]{6}$")
JOB_ID_RE = re.compile(r"^[0-9a-f]{32}$")
APP_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,40}$")
PART_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")

# Apps whose YunoHost backup scripts cover family data. Jellyfin and Immich are
# intentionally absent: their libraries and metadata can fill an 8 GB disk.
CORE_APP_IDS: tuple[str, ...] = (
    "synapse",
    "element",
    "nextcloud",
    "mobilizon",
    "owntracks",
    "traccar",
)
EXCLUDED_APP_IDS = frozenset({"jellyfin", "immich"})

# System hooks to request by name. An empty ``--system`` would also select
# data_multimedia (/home/yunohost.multimedia), data_home, and data_mail.
SYSTEM_PARTS: tuple[str, ...] = (
    "conf_ldap",
    "conf_ynh_settings",
    "conf_ynh_certs",
    "conf_manually_modified_files",
    "conf_tinywebstack",
)
REQUIRED_SYSTEM_PARTS = frozenset({"conf_ldap", "conf_ynh_settings", "conf_tinywebstack"})
EXCLUDED_SYSTEM_PARTS = frozenset(
    {"data_multimedia", "data_home", "data_mail", "data_xmpp"}
)

HOOK_FILES = {
    "conf_ldap": "/usr/share/yunohost/hooks/backup/05-conf_ldap",
    "conf_ynh_settings": "/usr/share/yunohost/hooks/backup/20-conf_ynh_settings",
    "conf_ynh_certs": "/usr/share/yunohost/hooks/backup/21-conf_ynh_certs",
    "conf_manually_modified_files": "/usr/share/yunohost/hooks/backup/50-conf_manually_modified_files",
    "conf_tinywebstack": "/etc/yunohost/hooks.d/backup/99-conf_tinywebstack",
}

DEFAULT_ARCHIVE_DIR = "/home/yunohost.backup/archives"
DEFAULT_STATE_DIR = "/var/lib/tinywebstack/backup"
DEFAULT_SETTINGS_PATH = "/etc/tinywebstack/backup-settings.json"
DEFAULT_MIN_FREE_BYTES = 2 * 1024 * 1024 * 1024
HARD_MIN_FREE_BYTES = 512 * 1024 * 1024
MAX_DELETES_PER_RUN = 20
EXPORT_PREFIXES = ("/mnt/", "/media/", "/run/media/")
TIMER_NAME = "tinywebstack-family-backup.timer"
SERVICE_NAME = "tinywebstack-family-backup.service"
WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")

APP_COVERAGE = {
    "synapse": "chats and files sent in chat",
    "element": "the Element web settings (chat history itself is in the chat app)",
    "nextcloud": "calendars",
    "mobilizon": "events",
    "owntracks": "location history",
    "traccar": "location history",
}

_SECRET_RE = re.compile(
    r"(?i)(password|passwd|secret|token|authorization|api_key|credential|bearer)"
    r"(\s*[=:]\s*|\s+)(\S+)"
)
_TWS_TOKEN_RE = re.compile(r"tws_[A-Za-z0-9_-]+")


class BackupError(Exception):
    """A backup step failed in a way the parent can be told about."""


@dataclass
class Settings:
    frequency: str = "off"  # off, daily, weekly
    hour: int = 3
    minute: int = 15
    weekday: int = 6  # Monday = 0, Sunday = 6
    keep_last: int = 3
    max_age_days: int = 90
    min_free_bytes: int = DEFAULT_MIN_FREE_BYTES

    def as_dict(self) -> Dict[str, Any]:
        return {
            "version": 1,
            "frequency": self.frequency,
            "hour": self.hour,
            "minute": self.minute,
            "weekday": self.weekday,
            "keep_last": self.keep_last,
            "max_age_days": self.max_age_days,
            "min_free_bytes": self.min_free_bytes,
        }


@dataclass
class ArchiveRecord:
    archive_id: str
    created_at: datetime


@dataclass
class TargetSelection:
    apps: List[str]
    system_parts: List[str]
    notes: List[str] = field(default_factory=list)


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def settings_path() -> Path:
    return Path(os.environ.get("TWS_BACKUP_SETTINGS_PATH", DEFAULT_SETTINGS_PATH))


def state_dir() -> Path:
    return Path(os.environ.get("TWS_BACKUP_STATE_DIR", DEFAULT_STATE_DIR))


def archive_dir() -> Path:
    return Path(os.environ.get("TWS_BACKUP_ARCHIVE_DIR", DEFAULT_ARCHIVE_DIR))


def redact(text: str, limit: int = 500) -> str:
    """Strip credential-shaped text before it is stored or shown."""
    cleaned = _SECRET_RE.sub(lambda m: f"{m.group(1)}=[redacted]", text or "")
    cleaned = _TWS_TOKEN_RE.sub("tws_[redacted]", cleaned)
    cleaned = cleaned.replace("\x00", "")
    cleaned = cleaned.strip()
    if len(cleaned) > limit:
        cleaned = cleaned[-limit:]
    return cleaned


def validate_settings(data: Mapping[str, Any]) -> Settings:
    frequency = str(data.get("frequency", "off")).strip().lower()
    if frequency not in {"off", "daily", "weekly"}:
        raise BackupError("Choose off, daily, or weekly.")
    try:
        hour = int(data["hour"])
        minute = int(data["minute"])
        weekday = int(data["weekday"])
        keep_last = int(data["keep_last"])
        max_age_days = int(data["max_age_days"])
        min_free_gb = data.get("min_free_gb")
        if min_free_gb is None:
            min_free_bytes = int(data.get("min_free_bytes", DEFAULT_MIN_FREE_BYTES))
        else:
            min_free_bytes = int(min_free_gb) * 1024 * 1024 * 1024
    except (KeyError, TypeError, ValueError) as exc:
        raise BackupError("Backup settings must be whole numbers.") from exc
    if not 0 <= hour <= 23:
        raise BackupError("Hour must be from 0 to 23.")
    if not 0 <= minute <= 59:
        raise BackupError("Minute must be from 0 to 59.")
    if not 0 <= weekday <= 6:
        raise BackupError("Pick a day of the week.")
    if not 1 <= keep_last <= 30:
        raise BackupError("Keep between 1 and 30 backups.")
    if not 0 <= max_age_days <= 3650:
        raise BackupError("Age limit must be from 0 to 3650 days.")
    if min_free_bytes < 1024 * 1024 * 1024 or min_free_bytes > 100 * 1024 * 1024 * 1024:
        raise BackupError("Free-space requirement must be from 1 to 100 GB.")
    return Settings(
        frequency=frequency,
        hour=hour,
        minute=minute,
        weekday=weekday,
        keep_last=keep_last,
        max_age_days=max_age_days,
        min_free_bytes=min_free_bytes,
    )


def default_settings() -> Settings:
    return Settings()


def load_settings(path: Optional[Path] = None) -> Settings:
    path = path or settings_path()
    if not path.is_file():
        return default_settings()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default_settings()
    if not isinstance(raw, dict):
        return default_settings()
    try:
        return validate_settings(raw)
    except BackupError:
        return default_settings()


def save_settings(settings: Settings, path: Optional[Path] = None) -> None:
    path = path or settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(settings.as_dict(), indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o640)
    os.replace(tmp, path)


def on_calendar(settings: Settings) -> str:
    """systemd OnCalendar value built only from validated numbers."""
    if settings.frequency == "off":
        raise BackupError("Automatic backups are off.")
    clock = f"{settings.hour:02d}:{settings.minute:02d}:00"
    if settings.frequency == "daily":
        return f"*-*-* {clock}"
    day = WEEKDAYS[settings.weekday]
    return f"{day} *-*-* {clock}"


def render_systemd_units(settings: Settings) -> Dict[str, str]:
    calendar = on_calendar(settings)
    if not re.fullmatch(r"[A-Za-z0-9:*-]+(?: [A-Za-z0-9:*-]+)*", calendar):
        raise BackupError("Refusing to write a schedule value.")
    service = (
        "[Unit]\n"
        "Description=TinyWeb family backup\n\n"
        "[Service]\n"
        "Type=oneshot\n"
        "ExecStart=/usr/local/sbin/tws-family-backup-privileged run-scheduled\n"
        "Nice=10\n"
    )
    timer = (
        "[Unit]\n"
        "Description=TinyWeb family backup schedule\n\n"
        "[Timer]\n"
        f"OnCalendar={calendar}\n"
        "Persistent=false\n"
        f"Unit={SERVICE_NAME}\n\n"
        "[Install]\n"
        "WantedBy=timers.target\n"
    )
    return {SERVICE_NAME: service, TIMER_NAME: timer}


def apply_schedule(
    settings: Settings,
    *,
    unit_dir: Path,
    run: Callable[[Sequence[str]], int],
) -> None:
    """Enable or disable this box's TinyWeb timer. Does not touch other timers."""
    timer_path = unit_dir / TIMER_NAME
    if settings.frequency == "off":
        if not timer_path.is_file():
            return
        if run(["systemctl", "disable", "--now", TIMER_NAME]) != 0:
            raise BackupError("Could not turn off the backup schedule.")
        return
    units = render_systemd_units(settings)
    unit_dir.mkdir(parents=True, exist_ok=True)
    for name, body in units.items():
        dest = unit_dir / name
        tmp = dest.with_suffix(dest.suffix + ".tmp")
        tmp.write_text(body, encoding="utf-8")
        os.chmod(tmp, 0o644)
        os.replace(tmp, dest)
    if run(["systemctl", "daemon-reload"]) != 0:
        raise BackupError("Could not reload the scheduler.")
    if run(["systemctl", "enable", "--now", TIMER_NAME]) != 0:
        run(["systemctl", "disable", "--now", TIMER_NAME])
        raise BackupError("Could not turn on the backup schedule.")


def new_archive_id(now: Optional[datetime] = None) -> str:
    moment = now or utcnow()
    archive_id = moment.astimezone(timezone.utc).strftime("tinyweb-%Y%m%d-%H%M%S")
    if not ARCHIVE_ID_RE.match(archive_id):
        raise BackupError("Could not name the backup.")
    return archive_id


def require_archive_id(archive_id: str) -> str:
    if not isinstance(archive_id, str) or not ARCHIVE_ID_RE.match(archive_id):
        raise BackupError("Unknown backup.")
    return archive_id


def require_job_id(job_id: str) -> str:
    if not isinstance(job_id, str) or not JOB_ID_RE.match(job_id):
        raise BackupError("Unknown backup job.")
    return job_id


def select_targets(installed_apps: Iterable[str], present_parts: Iterable[str]) -> TargetSelection:
    installed = {a for a in installed_apps if isinstance(a, str)}
    present = {p for p in present_parts if isinstance(p, str)}
    apps = [app for app in CORE_APP_IDS if app in installed and app not in EXCLUDED_APP_IDS]
    parts = [part for part in SYSTEM_PARTS if part in present and part not in EXCLUDED_SYSTEM_PARTS]
    missing = sorted(REQUIRED_SYSTEM_PARTS - set(parts))
    if missing:
        raise BackupError(
            "TinyWeb cannot take a backup yet because a required YunoHost backup piece "
            f"is missing: {', '.join(missing)}."
        )
    notes: List[str] = []
    if "synapse" not in apps:
        notes.append("The chat app is not installed, so chats are not in this backup.")
    if "nextcloud" not in apps:
        notes.append("Calendars are not installed, so they are not in this backup.")
    if "mobilizon" not in apps:
        notes.append("Events are not installed, so they are not in this backup.")
    if "owntracks" not in apps and "traccar" not in apps:
        notes.append("Location history is not installed, so it is not in this backup.")
    return TargetSelection(apps=apps, system_parts=parts, notes=notes)


def build_create_command(archive_id: str, selection: TargetSelection) -> List[str]:
    """Argv for ``yunohost backup create``. No shell, no excluded parts."""
    require_archive_id(archive_id)
    apps: List[str] = []
    for app in selection.apps:
        if app in EXCLUDED_APP_IDS or not APP_ID_RE.match(app):
            raise BackupError("Refusing to back up an app that is not on the family list.")
        if app not in CORE_APP_IDS:
            raise BackupError("Refusing to back up an app that is not on the family list.")
        apps.append(app)
    parts: List[str] = []
    for part in selection.system_parts:
        if part in EXCLUDED_SYSTEM_PARTS or not PART_RE.match(part):
            raise BackupError("Refusing a system backup piece that is not on the family list.")
        if part not in SYSTEM_PARTS:
            raise BackupError("Refusing a system backup piece that is not on the family list.")
        parts.append(part)
    if not parts:
        raise BackupError("Refusing to run a backup with no system pieces.")
    command = [
        "yunohost",
        "backup",
        "create",
        "--name",
        archive_id,
        "--description",
        "TinyWeb family backup",
        "--system",
        *parts,
    ]
    if apps:
        command.extend(["--apps", *apps])
    return command


def build_delete_command(archive_id: str) -> List[str]:
    require_archive_id(archive_id)
    return ["yunohost", "backup", "delete", archive_id]


def human_bytes(n: Optional[int]) -> str:
    if n is None:
        return "unknown"
    value = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{n} B"


def space_ok(free_bytes: int, settings: Settings) -> bool:
    needed = max(settings.min_free_bytes, HARD_MIN_FREE_BYTES)
    return free_bytes >= needed


def describe_space(free_bytes: int, needed: int, nextcloud_bytes: Optional[int]) -> Dict[str, Any]:
    """Disk verdict plus a plain-language size note. Nextcloud files are included."""
    ok = free_bytes >= needed
    note = (
        "Nextcloud's data folder is included, not only calendars. "
        "Chat uploads are included too. Jellyfin movies are not."
    )
    if nextcloud_bytes is not None:
        note = (
            f"Nextcloud files are about {human_bytes(nextcloud_bytes)}. "
            "This backup copies that folder in addition to calendars, chats, and databases. "
            "Jellyfin movies are not included."
        )
        if free_bytes < nextcloud_bytes + needed:
            ok = False
            note += " Free space looks too small for that copy."
    return {"ok": ok, "size_note": note}


def coverage_rows() -> List[Dict[str, str]]:
    """Parent-facing coverage. Wording is tested so it cannot drift silently."""
    return [
        {
            "title": "Family logins",
            "state": "included",
            "detail": (
                "Accounts, groups, and passwords are included by YunoHost's LDAP backup "
                "(a directory dump, not a copy of the live database files)."
            ),
        },
        {
            "title": "Who can use which app",
            "state": "included",
            "detail": "YunoHost permissions are included with the system settings.",
        },
        {
            "title": "Chats and files sent in chat",
            "state": "included",
            "detail": (
                "The chat app's backup dumps its database and includes uploaded files. "
                "Encrypted chats still need the recovery key that was shown on the phone. "
                "That key is not stored here."
            ),
        },
        {
            "title": "Calendars",
            "state": "included",
            "detail": (
                "Calendar events are in the Nextcloud database dump. Nextcloud's own backup "
                "also includes its data folder, so files stored there are in this archive too."
            ),
        },
        {
            "title": "Events",
            "state": "included",
            "detail": "Events are in the Mobilizon database dump, with its uploads.",
        },
        {
            "title": "Location history",
            "state": "included",
            "detail": (
                "Included when OwnTracks or Traccar is installed, using that app's YunoHost "
                "backup. OwnTracks copies its data folder; it does not take a separate database dump."
            ),
        },
        {
            "title": "Family rules and phone sign-ins",
            "state": "included",
            "detail": (
                "The permissions database and the phone sign-in database are snapshotted "
                "with SQLite's backup API. TinyWeb settings needed to bring the home back "
                "are included with them."
            ),
        },
        {
            "title": "Movies, shows, and photo libraries",
            "state": "left out",
            "detail": (
                "Jellyfin and Immich are not part of this backup. The shared media folder "
                "(/home/yunohost.multimedia) is not part of it either. Copy that folder to "
                "another disk yourself. A movie library would fill this computer's backup."
            ),
        },
        {
            "title": "Mail and Linux home folders",
            "state": "left out",
            "detail": "Mailboxes and per-person home folders are not part of this family backup.",
        },
        {
            "title": "The installer's password file",
            "state": "left out",
            "detail": (
                "The password file kept on the computer that installed TinyWeb is not on this "
                "box, so it is not in the archive."
            ),
        },
    ]


def retention_ids(
    records: Sequence[ArchiveRecord],
    settings: Settings,
    now: Optional[datetime] = None,
) -> List[str]:
    """Ids of managed archives to delete. Never returns an unrecognised name.

    The newest backup is always kept. At most ``MAX_DELETES_PER_RUN`` names are
    returned, oldest first. Callers must delete only these names, and only
    through ``yunohost backup delete``.
    """
    moment = now or utcnow()
    chosen: Dict[str, datetime] = {}
    for record in records:
        if not ARCHIVE_ID_RE.match(record.archive_id):
            continue
        created = record.created_at
        if created.tzinfo is None:
            created = created.replace(tzinfo=timezone.utc)
        previous = chosen.get(record.archive_id)
        if previous is None or created > previous:
            chosen[record.archive_id] = created
    ordered = sorted(chosen.items(), key=lambda item: item[1], reverse=True)
    doomed: List[str] = []
    kept = 0
    age_limit = timedelta(days=settings.max_age_days) if settings.max_age_days > 0 else None
    for archive_id, created in ordered:
        too_old = age_limit is not None and (moment - created) > age_limit
        over_count = kept >= settings.keep_last
        if kept == 0:
            kept += 1
            continue
        if too_old or over_count:
            doomed.append(archive_id)
            continue
        kept += 1
    oldest_first = list(reversed(doomed))
    return oldest_first[:MAX_DELETES_PER_RUN]


def archive_file_ok(archive_directory: Path, archive_id: str) -> bool:
    """True when the archive is a regular file inside the archive directory."""
    try:
        require_archive_id(archive_id)
    except BackupError:
        return False
    path = archive_directory / f"{archive_id}.tar"
    try:
        st = path.lstat()
    except OSError:
        return False
    if not stat_is_regular(st.st_mode):
        return False
    try:
        real = path.resolve()
        root = archive_directory.resolve()
    except OSError:
        return False
    return real.parent == root and real.is_file()


def inspect_archive(path: Path) -> Optional[Tuple[int, int, int, bool]]:
    """Open ``path`` with ``O_NOFOLLOW``.

    Returns ``(st_dev, st_ino, has_tinyweb_manifest)`` for a regular file, or
    ``None`` when the path is missing, a symlink, or not a regular file.
    """
    import tarfile

    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat_is_regular(st.st_mode):
            return None
        fileobj = os.fdopen(fd, "rb")
        fd = -1
        has_marker = False
        with tarfile.open(fileobj=fileobj, mode="r:*") as tar:
            for member in tar:
                name = member.name.lstrip("./")
                if name.endswith("conf/tinywebstack/manifest.json") and member.isfile():
                    has_marker = True
                    break
        return (st.st_dev, st.st_ino, st.st_size, has_marker)
    except (tarfile.TarError, OSError):
        return None
    finally:
        if fd >= 0:
            os.close(fd)


def tinyweb_marker_present(path: Path) -> Optional[Tuple[int, int, int]]:
    """Inode of a regular archive that contains the TinyWeb manifest."""
    viewed = inspect_archive(path)
    if viewed is None or not viewed[3]:
        return None
    return (viewed[0], viewed[1], viewed[2])


def archive_inode(path: Path) -> Optional[Tuple[int, int, int]]:
    """``(st_dev, st_ino, st_size)`` of a regular file opened with ``O_NOFOLLOW``."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
    finally:
        os.close(fd)
    if not stat_is_regular(st.st_mode):
        return None
    return (st.st_dev, st.st_ino, st.st_size)


def same_archive_inode(path: Path, ident: Tuple[int, int, int]) -> bool:
    """True when ``path`` is still the same regular file (``O_NOFOLLOW``)."""
    current = archive_inode(path)
    return current == ident


def open_export_dir(raw: str) -> int:
    """Open a removable-disk directory. Refuse a symlink in any path component."""
    import errno

    text = validate_export_path(raw)
    path = Path(text)
    try:
        dir_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    except OSError as exc:
        raise BackupError("That folder does not exist. Plug in the disk and try again.") from exc
    try:
        for part in path.parts[1:]:
            try:
                nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)
            except OSError as exc:
                if exc.errno == errno.ELOOP:
                    raise BackupError("That folder is a link. Choose the real folder on the disk.") from exc
                raise BackupError("That folder does not exist. Plug in the disk and try again.") from exc
            os.close(dir_fd)
            dir_fd = nxt
        st = os.fstat(dir_fd)
        if not _is_dir_mode(st.st_mode):
            raise BackupError("That folder does not exist. Plug in the disk and try again.")
        return dir_fd
    except BackupError:
        os.close(dir_fd)
        raise
    except Exception:
        os.close(dir_fd)
        raise


def _is_dir_mode(mode: int) -> bool:
    import stat

    return stat.S_ISDIR(mode)


def stat_is_regular(mode: int) -> bool:
    import stat

    return stat.S_ISREG(mode)


def validate_export_path(raw: str) -> str:
    """Accept a folder on a removable disk. Reject traversal and other roots."""
    if not isinstance(raw, str):
        raise BackupError("Choose a folder on a disk plugged into this box.")
    text = raw.strip()
    if not text.startswith("/") or text.startswith("//") or "\x00" in text or "\n" in text:
        raise BackupError("Use a folder under /mnt, /media, or /run/media.")
    parts = Path(text).parts
    if ".." in parts or "." in parts:
        raise BackupError("That folder path is not allowed.")
    if not any(text.startswith(prefix) for prefix in EXPORT_PREFIXES):
        raise BackupError("Copies stay on a disk under /mnt, /media, or /run/media.")
    rest = text
    for prefix in EXPORT_PREFIXES:
        if text.startswith(prefix):
            rest = text[len(prefix) :]
            break
    if not rest or rest.strip("/") == "":
        raise BackupError("Choose a folder on the disk, not the disk's parent.")
    return str(Path(text))


def assert_export_dir(raw: str) -> Path:
    """Resolve the folder and refuse symlinks that leave the allowed prefixes."""
    text = validate_export_path(raw)
    path = Path(text)
    if path.is_symlink():
        raise BackupError("That folder is a link. Choose the real folder on the disk.")
    try:
        real = path.resolve()
    except OSError as exc:
        raise BackupError("That folder does not exist. Plug in the disk and try again.") from exc
    try:
        validate_export_path(str(real))
    except BackupError as exc:
        raise BackupError("That folder points outside the disks TinyWeb can copy to.") from exc
    if not real.is_dir():
        raise BackupError("That folder does not exist. Plug in the disk and try again.")
    return real


def snapshot_sqlite(src: Path, dest: Path) -> None:
    """Consistent SQLite snapshot via the backup API. Does not copy the live file."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() or dest.is_symlink():
        if dest.is_symlink() or not dest.is_file():
            raise BackupError(f"Refusing to replace {dest.name}")
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
    check = sqlite3.connect(f"file:{dest}?mode=ro", uri=True)
    try:
        row = check.execute("PRAGMA integrity_check").fetchone()
    finally:
        check.close()
    if not row or row[0] != "ok":
        raise BackupError(f"Snapshot of {src.name} failed its integrity check.")


def restore_sqlite_snapshot(snapshot: Path, dest: Path) -> None:
    """Replace ``dest`` with the snapshot using a temp file and atomic rename."""
    if snapshot.is_symlink() or not snapshot.is_file():
        raise BackupError("Backup snapshot is missing.")
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".restore-tmp")
    if tmp.exists() or tmp.is_symlink():
        if tmp.is_symlink():
            raise BackupError("Refusing to write a snapshot onto a link.")
        tmp.unlink()
    snapshot_sqlite(snapshot, tmp)
    os.replace(tmp, dest)
    for suffix in ("-wal", "-shm"):
        side = Path(str(dest) + suffix)
        if side.is_symlink():
            continue
        if side.is_file():
            side.unlink()


# --- jobs -----------------------------------------------------------------


SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    status TEXT NOT NULL,
    phase TEXT NOT NULL,
    archive_id TEXT,
    pid INTEGER,
    created_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT,
    actor TEXT NOT NULL DEFAULT '',
    detail TEXT NOT NULL DEFAULT '',
    summary TEXT NOT NULL DEFAULT '',
    export_path TEXT NOT NULL DEFAULT ''
);
"""


def job_lock(directory: Path):
    """Non-blocking exclusive lock. Returns a fd to hold, or None if busy."""
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "job.lock"
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o660)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    return fd


def connect(directory: Optional[Path] = None) -> sqlite3.Connection:
    directory = directory or state_dir()
    directory.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(directory / "jobs.db", timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=5000")
    conn.executescript(SCHEMA)
    try:
        os.chmod(directory / "jobs.db", 0o660)
    except OSError:
        pass
    return conn


def _row_dict(row: sqlite3.Row) -> Dict[str, Any]:
    return {key: row[key] for key in row.keys()}


def insert_job(
    conn: sqlite3.Connection,
    *,
    kind: str,
    actor: str,
    export_path: str = "",
    archive_id: str = "",
) -> Dict[str, Any]:
    if kind not in {"backup", "copy"}:
        raise BackupError("Unknown job.")
    job_id = uuid.uuid4().hex
    now = utcnow().isoformat()
    conn.execute(
        """
        INSERT INTO jobs (
            id, kind, status, phase, archive_id, pid, created_at, actor, detail, summary, export_path
        ) VALUES (?, ?, 'queued', 'queued', ?, NULL, ?, ?, '', '', ?)
        """,
        (job_id, kind, archive_id or None, now, actor, export_path),
    )
    conn.commit()
    return get_job(conn, job_id)


def get_job(conn: sqlite3.Connection, job_id: str) -> Dict[str, Any]:
    require_job_id(job_id)
    row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    if row is None:
        raise BackupError("Unknown backup job.")
    return _row_dict(row)


def list_jobs(conn: sqlite3.Connection, limit: int = 30) -> List[Dict[str, Any]]:
    rows = conn.execute(
        "SELECT * FROM jobs ORDER BY created_at DESC, rowid DESC LIMIT ?",
        (max(1, min(limit, 100)),),
    ).fetchall()
    return [_row_dict(row) for row in rows]


def has_succeeded_backup(conn: sqlite3.Connection, archive_id: str) -> bool:
    """True when this tool recorded a successful backup with this exact id."""
    require_archive_id(archive_id)
    row = conn.execute(
        """
        SELECT 1 FROM jobs
        WHERE kind = 'backup' AND status = 'succeeded' AND archive_id = ?
        LIMIT 1
        """,
        (archive_id,),
    ).fetchone()
    return row is not None


def update_job(conn: sqlite3.Connection, job_id: str, **fields: Any) -> Dict[str, Any]:
    require_job_id(job_id)
    allowed = {
        "status",
        "phase",
        "archive_id",
        "pid",
        "started_at",
        "finished_at",
        "detail",
        "summary",
        "export_path",
    }
    sets = []
    values: List[Any] = []
    for key, value in fields.items():
        if key not in allowed:
            raise BackupError("Refusing to store an unknown job field.")
        if key == "detail" and isinstance(value, str):
            value = redact(value)
        if key == "archive_id" and value:
            require_archive_id(value)
        sets.append(f"{key} = ?")
        values.append(value)
    if not sets:
        return get_job(conn, job_id)
    values.append(job_id)
    conn.execute(f"UPDATE jobs SET {', '.join(sets)} WHERE id = ?", values)
    conn.commit()
    return get_job(conn, job_id)


def pid_alive(pid: Optional[int]) -> bool:
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def reconcile_jobs(conn: sqlite3.Connection, now: Optional[datetime] = None) -> None:
    """Mark jobs whose worker died so a restart cannot leave a false 'running'."""
    moment = now or utcnow()
    rows = conn.execute(
        "SELECT * FROM jobs WHERE status IN ('queued', 'running')"
    ).fetchall()
    for row in rows:
        job = _row_dict(row)
        if pid_alive(job["pid"]):
            continue
        created = datetime.fromisoformat(job["created_at"])
        if created.tzinfo is None:
            created = created.replace(tzinfo=timezone.utc)
        age = (moment - created).total_seconds()
        if job["status"] == "queued" and not job["pid"] and age < 30:
            continue
        if job["status"] == "queued":
            detail = "Backup did not start."
        else:
            detail = "Backup stopped before it finished. The box may have restarted."
        update_job(
            conn,
            job["id"],
            status="failed",
            phase="failed",
            finished_at=moment.isoformat(),
            detail=detail,
        )


def active_job(conn: sqlite3.Connection) -> Optional[Dict[str, Any]]:
    reconcile_jobs(conn)
    row = conn.execute(
        """
        SELECT * FROM jobs
        WHERE status IN ('queued', 'running')
        ORDER BY created_at DESC
        LIMIT 1
        """
    ).fetchone()
    if row is None:
        return None
    return _row_dict(row)


def managed_archive_records(conn: sqlite3.Connection) -> List[ArchiveRecord]:
    rows = conn.execute(
        """
        SELECT archive_id, created_at FROM jobs
        WHERE kind = 'backup' AND status = 'succeeded' AND archive_id IS NOT NULL
        """
    ).fetchall()
    records: List[ArchiveRecord] = []
    for row in rows:
        try:
            created = datetime.fromisoformat(row["created_at"])
        except (TypeError, ValueError):
            continue
        records.append(ArchiveRecord(archive_id=row["archive_id"], created_at=created))
    return records


def phase_label(phase: str) -> str:
    return {
        "queued": "Waiting to start",
        "preflight": "Checking disk space",
        "backup": "Backing up",
        "retention": "Removing old backups",
        "copy": "Copying off this box",
        "succeeded": "Finished",
        "failed": "Failed",
    }.get(phase, phase)


def summary_text(summary_json: str) -> str:
    if not summary_json:
        return ""
    try:
        data = json.loads(summary_json)
    except json.JSONDecodeError:
        return ""
    if not isinstance(data, dict):
        return ""
    labels = []
    for app in data.get("apps") or []:
        label = APP_COVERAGE.get(str(app))
        if label:
            labels.append(label)
    if "conf_ldap" in (data.get("system") or []):
        labels.append("family logins")
    if "conf_tinywebstack" in (data.get("system") or []):
        labels.append("family rules, phone sign-ins, and home settings")
    notes = [str(n) for n in (data.get("notes") or [])]
    parts = []
    if labels:
        parts.append("Included " + ", ".join(labels) + ".")
    parts.extend(notes)
    return " ".join(parts)
