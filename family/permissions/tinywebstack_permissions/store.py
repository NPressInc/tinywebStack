"""SQLite-backed role→permission store for the tinywebStack family layer (F1.3).

Stdlib sqlite3 only (+ PyYAML for the seed role files). The DB is runtime
state; the two in-repo role YAMLs (roles/parent.yaml, roles/kid.yaml) are
migrations that create/populate role definitions. Enforcement code queries
this store instead of hardcoding rules.

DB location resolution (first match wins):
  1. explicit ``db_path`` argument
  2. config dict key ``permissions_db``
  3. env var ``TWS_PERMISSIONS_DB``
  4. ``/etc/tinywebstack/permissions.db``

Fallback contract: callers treat a *missing* DB file as "not seeded yet" and
keep their legacy file-backed behaviour (family-policy.json). This keeps the
lab verdicts identical before the seed step has run.
"""

from __future__ import annotations

import json
import logging
import os
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

log = logging.getLogger(__name__)

try:  # PyYAML is only needed for the seed step; reads never require it.
    import yaml  # type: ignore
except ImportError:  # pragma: no cover
    yaml = None  # type: ignore[assignment]

SCHEMA_VERSION = 1
DEFAULT_DB_PATH = "/etc/tinywebstack/permissions.db"
ENV_DB_VAR = "TWS_PERMISSIONS_DB"

BOOL_KEYS = (
    "can_create_rooms",
    "can_create_group_rooms",
    "can_send_3pid_invites",
    "can_publish_rooms",
    "events_enabled",
)
STR_KEYS = ("mobilizon_role",)
LIST_KEYS = ("allowlist_mxids", "allowlist_domains")
DICT_KEYS = ("quiet_hours",)
PERMISSION_KEYS = BOOL_KEYS + STR_KEYS + LIST_KEYS + DICT_KEYS

_KNOWN_META_KEYS = ("server_name", "trusted_domains", "reject_encryption")


def get_db_path(config: Optional[Dict[str, Any]] = None) -> Path:
    """Resolve the permissions DB path (config key > env > default)."""
    if config:
        raw = config.get("permissions_db")
        if raw:
            return Path(str(raw))
    env = os.environ.get(ENV_DB_VAR, "").strip()
    if env:
        return Path(env)
    return Path(DEFAULT_DB_PATH)


def resolve_db_path(
    config: Optional[Dict[str, Any]] = None, require_existing: bool = False
) -> Optional[Path]:
    """Return the DB path if it should be consulted, else None.

    With ``require_existing=True`` returns None when the file is absent —
    enforcement callers use that to fall back to the legacy JSON policy.
    """
    path = get_db_path(config)
    if require_existing and not path.is_file():
        return None
    return path


def effective_db_path(config: Optional[Dict[str, Any]] = None) -> str:
    return str(get_db_path(config))


@dataclass
class QuietHours:
    """Mirror of tinywebstack_family.policy.QuietHours.

    Duplicated deliberately: the Synapse module installs standalone into the
    synapse venv (pip --no-deps) and must not import this package, and this
    package must not import the Synapse module (the dashboard uses it too).
    Keep ``is_active`` behaviourally identical to the policy module version.
    """

    start: str  # HH:MM
    end: str
    timezone: str
    days: List[int] = field(default_factory=lambda: list(range(7)))

    def is_active(self, when: Optional[datetime] = None) -> bool:
        when = when or datetime.now(tz=_utc())
        try:
            from zoneinfo import ZoneInfo

            tz = ZoneInfo(self.timezone)
        except Exception:
            log.warning("Invalid quiet-hours timezone %r", self.timezone)
            return False
        local = when.astimezone(tz)
        if local.weekday() not in self.days:
            return False
        start_h, start_m = (int(x) for x in self.start.split(":", 1))
        end_h, end_m = (int(x) for x in self.end.split(":", 1))
        start_t = time(start_h, start_m)
        end_t = time(end_h, end_m)
        now_t = local.time()
        if start_t <= end_t:
            return start_t <= now_t < end_t
        return now_t >= start_t or now_t < end_t

    def to_dict(self) -> Dict[str, Any]:
        return {
            "start": self.start,
            "end": self.end,
            "timezone": self.timezone,
            "days": list(self.days),
        }

    @classmethod
    def from_dict(cls, raw: Any) -> Optional["QuietHours"]:
        if not isinstance(raw, dict) or not raw.get("start") or not raw.get("end"):
            return None
        try:
            days = [int(d) for d in raw.get("days", list(range(7)))]
        except (TypeError, ValueError):
            days = list(range(7))
        return cls(
            start=str(raw["start"]),
            end=str(raw["end"]),
            timezone=str(raw.get("timezone", "UTC")),
            days=days,
        )


def _utc() -> Any:
    from datetime import timezone

    return timezone.utc


@dataclass
class PermissionSet:
    """Effective permissions for one user (role defaults merged with overrides)."""

    mxid: str
    username: str
    role: str
    is_admin: bool = False
    can_create_rooms: bool = True
    can_create_group_rooms: bool = True
    can_send_3pid_invites: bool = True
    can_publish_rooms: bool = True
    events_enabled: bool = True
    mobilizon_role: str = "member"
    allowlist_mxids: Set[str] = field(default_factory=set)
    allowlist_domains: Set[str] = field(default_factory=set)
    quiet_hours: Optional[QuietHours] = None

    def to_dict(self) -> Dict[str, Any]:
        out: Dict[str, Any] = {
            "mxid": self.mxid,
            "username": self.username,
            "role": self.role,
            "is_admin": self.is_admin,
        }
        for key in BOOL_KEYS:
            out[key] = getattr(self, key)
        for key in STR_KEYS:
            out[key] = getattr(self, key)
        for key in LIST_KEYS:
            out[key] = sorted(getattr(self, key))
        out["quiet_hours"] = self.quiet_hours.to_dict() if self.quiet_hours else None
        return out


def _coerce(key: str, value: Any) -> Any:
    if key in BOOL_KEYS:
        return bool(value)
    if key in STR_KEYS:
        return str(value)
    if key in LIST_KEYS:
        if value is None:
            return set()
        if isinstance(value, (list, tuple, set)):
            return {str(v).strip() for v in value if str(v).strip()}
        return set()
    if key == "quiet_hours":
        return QuietHours.from_dict(value)
    return value


def default_role_permissions() -> Dict[str, Dict[str, Any]]:
    """Built-in role defaults used when the DB has no rows for a role."""
    return {
        "parent": {
            "can_create_rooms": True,
            "can_create_group_rooms": True,
            "can_send_3pid_invites": True,
            "can_publish_rooms": True,
            "events_enabled": True,
            "mobilizon_role": "admin",
            "allowlist_mxids": [],
            "allowlist_domains": [],
            "quiet_hours": None,
        },
        "kid": {
            "can_create_rooms": True,
            "can_create_group_rooms": False,
            "can_send_3pid_invites": False,
            "can_publish_rooms": False,
            "events_enabled": True,
            "mobilizon_role": "member",
            "allowlist_mxids": [],
            "allowlist_domains": [],
            "quiet_hours": None,
        },
    }


def load_role_yaml(path: Path) -> Dict[str, Any]:
    """Load one role seed file: {role, is_admin, permissions{...}}."""
    if yaml is None:
        raise RuntimeError("PyYAML is required to seed roles from YAML")
    data = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not data.get("role"):
        raise ValueError(f"Invalid role seed file: {path}")
    perms = data.get("permissions") or {}
    if not isinstance(perms, dict):
        raise ValueError(f"permissions must be a mapping in {path}")
    unknown = sorted(set(perms) - set(PERMISSION_KEYS))
    if unknown:
        raise ValueError(f"Unknown permission keys {unknown} in {path}")
    return {
        "role": str(data["role"]).strip().lower(),
        "is_admin": bool(data.get("is_admin", False)),
        "permissions": perms,
    }


_SCHEMA_SQL = f"""
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS roles (
  name TEXT PRIMARY KEY,
  is_admin INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS role_permissions (
  role TEXT NOT NULL REFERENCES roles(name),
  key TEXT NOT NULL,
  value_json TEXT NOT NULL,
  PRIMARY KEY (role, key)
);
CREATE TABLE IF NOT EXISTS users (
  mxid TEXT PRIMARY KEY,
  username TEXT,
  role TEXT NOT NULL REFERENCES roles(name),
  server_name TEXT
);
CREATE TABLE IF NOT EXISTS user_permissions (
  mxid TEXT NOT NULL REFERENCES users(mxid),
  key TEXT NOT NULL,
  value_json TEXT NOT NULL,
  PRIMARY KEY (mxid, key)
);
"""


class PermissionsDB:
    """Thin library API over the SQLite permission store."""

    def __init__(self, db_path: str | Path | None = None, *, read_only: bool = False) -> None:
        self.path = Path(db_path) if db_path is not None else get_db_path()
        self._read_only = bool(read_only)
        if self._read_only:
            uri = f"file:{self.path.resolve()}?mode=ro"
            self._conn = sqlite3.connect(uri, uri=True, timeout=10)
            self._conn.row_factory = sqlite3.Row
            self._conn.execute("PRAGMA foreign_keys = ON")
            self._conn.execute("PRAGMA query_only = ON")
            self._verify_schema_readable()
        else:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self._conn = sqlite3.connect(str(self.path), timeout=10)
            self._conn.row_factory = sqlite3.Row
            self._conn.execute("PRAGMA foreign_keys = ON")
            self._ensure_schema()

    @classmethod
    def open_readonly(cls, db_path: str | Path) -> "PermissionsDB":
        return cls(db_path, read_only=True)

    def close(self) -> None:
        try:
            self._conn.close()
        except sqlite3.Error:
            pass

    def __enter__(self) -> "PermissionsDB":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    def _schema_version(self) -> int:
        cur = self._conn.execute("PRAGMA user_version")
        return int(cur.fetchone()[0])

    def _verify_schema_readable(self) -> None:
        version = self._schema_version()
        if version > SCHEMA_VERSION:
            raise RuntimeError(
                f"permissions DB schema v{version} newer than supported v{SCHEMA_VERSION}"
            )
        if version < SCHEMA_VERSION:
            log.warning(
                "permissions DB %s schema v%s (expected v%s); run family-permissions-seed as root",
                self.path,
                version,
                SCHEMA_VERSION,
            )

    def _ensure_schema(self) -> None:
        if self._read_only:
            return
        version = self._schema_version()
        if version > SCHEMA_VERSION:
            raise RuntimeError(
                f"permissions DB schema v{version} newer than supported v{SCHEMA_VERSION}"
            )
        if version >= SCHEMA_VERSION:
            return
        with self._conn:
            self._conn.executescript(_SCHEMA_SQL)
            self._conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
            self._conn.execute(
                "INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', ?)",
                (str(SCHEMA_VERSION),),
            )

    # ------------------------------------------------------------------ meta

    def set_meta(self, key: str, value: Any) -> None:
        with self._conn:
            self._conn.execute(
                "INSERT INTO meta(key, value) VALUES(?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (key, json.dumps(value)),
            )

    def get_meta(self, key: str, default: Any = None) -> Any:
        row = self._conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        if row is None:
            return default
        try:
            return json.loads(row["value"])
        except (json.JSONDecodeError, TypeError):
            return default

    @property
    def server_name(self) -> str:
        return str(self.get_meta("server_name", "") or "")

    def set_server_name(self, server_name: str) -> None:
        self.set_meta("server_name", server_name)

    @property
    def trusted_domains(self) -> Set[str]:
        raw = self.get_meta("trusted_domains", []) or []
        return {str(x) for x in raw} if isinstance(raw, list) else set()

    @trusted_domains.setter
    def trusted_domains(self, domains: Iterable[str]) -> None:
        self.set_meta("trusted_domains", sorted({str(d) for d in domains}))

    @property
    def reject_encryption(self) -> bool:
        return bool(self.get_meta("reject_encryption", True))

    @reject_encryption.setter
    def reject_encryption(self, value: bool) -> None:
        self.set_meta("reject_encryption", bool(value))

    # ----------------------------------------------------------------- roles

    def upsert_role(
        self, role: str, *, is_admin: bool = False, permissions: Optional[Dict[str, Any]] = None
    ) -> None:
        """Create/replace a role definition (YAML is authoritative for defaults)."""
        role = role.strip().lower()
        with self._conn:
            self._conn.execute(
                "INSERT INTO roles(name, is_admin) VALUES(?, ?) "
                "ON CONFLICT(name) DO UPDATE SET is_admin=excluded.is_admin",
                (role, 1 if is_admin else 0),
            )
            self._conn.execute("DELETE FROM role_permissions WHERE role=?", (role,))
            merged = dict(default_role_permissions().get(role, {}))
            if permissions:
                merged.update(permissions)
            for key, value in merged.items():
                if key not in PERMISSION_KEYS:
                    raise ValueError(f"Unknown permission key: {key}")
                self._conn.execute(
                    "INSERT INTO role_permissions(role, key, value_json) VALUES(?,?,?)",
                    (role, key, json.dumps(value)),
                )

    def seed_roles(self, role_files: Iterable[str | Path]) -> List[str]:
        seeded: List[str] = []
        for path in role_files:
            spec = load_role_yaml(Path(path))
            self.upsert_role(
                spec["role"], is_admin=spec["is_admin"], permissions=spec["permissions"]
            )
            seeded.append(spec["role"])
        return seeded

    def seed_default_roles(self) -> List[str]:
        """Create parent/kid roles from built-in defaults (idempotent)."""
        for role, perms in default_role_permissions().items():
            self.upsert_role(role, is_admin=(role == "parent"), permissions=perms)
        return sorted(default_role_permissions())

    def role_is_admin(self, role: str) -> bool:
        row = self._conn.execute(
            "SELECT is_admin FROM roles WHERE name=?", (role.strip().lower(),)
        ).fetchone()
        if row is None:
            return role.strip().lower() == "parent"
        return bool(row["is_admin"])

    # ----------------------------------------------------------------- users

    def set_role(self, mxid: str, role: str, *, username: Optional[str] = None,
                 server_name: Optional[str] = None) -> None:
        role = role.strip().lower()
        exists = self._conn.execute("SELECT 1 FROM roles WHERE name=?", (role,)).fetchone()
        if not exists:
            raise ValueError(f"Unknown role: {role} (seed it first)")
        if username is None and mxid.startswith("@") and ":" in mxid:
            username = mxid[1:].split(":", 1)[0]
        if server_name is None and ":" in mxid:
            server_name = mxid.split(":", 1)[1]
        with self._conn:
            self._conn.execute(
                "INSERT INTO users(mxid, username, role, server_name) VALUES(?,?,?,?) "
                "ON CONFLICT(mxid) DO UPDATE SET username=excluded.username, "
                "role=excluded.role, server_name=excluded.server_name",
                (mxid, username, role, server_name),
            )

    def remove_user(self, mxid: str) -> None:
        with self._conn:
            self._conn.execute("DELETE FROM user_permissions WHERE mxid=?", (mxid,))
            self._conn.execute("DELETE FROM users WHERE mxid=?", (mxid,))

    def _resolve_mxid(self, user: str) -> Optional[str]:
        row = self._conn.execute(
            "SELECT mxid FROM users WHERE mxid=?", (user,)
        ).fetchone()
        if row:
            return str(row["mxid"])
        row = self._conn.execute(
            "SELECT mxid FROM users WHERE username=? OR username=? LIMIT 1",
            (user, f"@{user}"),
        ).fetchone()
        return str(row["mxid"]) if row else None

    # ----------------------------------------------------------- permissions

    def set_permission(self, mxid: str, key: str, value: Any) -> None:
        if key not in PERMISSION_KEYS:
            raise ValueError(f"Unknown permission key: {key}")
        resolved = self._resolve_mxid(mxid) or mxid
        exists = self._conn.execute("SELECT 1 FROM users WHERE mxid=?", (resolved,)).fetchone()
        if not exists:
            raise KeyError(f"Unknown user: {resolved}")
        canonical = _canonical_value(key, value)
        with self._conn:
            self._conn.execute(
                "INSERT INTO user_permissions(mxid, key, value_json) VALUES(?,?,?) "
                "ON CONFLICT(mxid, key) DO UPDATE SET value_json=excluded.value_json",
                (resolved, key, json.dumps(canonical)),
            )

    def revoke_permission(self, mxid: str, key: str) -> None:
        """Drop the per-user override; the role default applies again."""
        resolved = self._resolve_mxid(mxid) or mxid
        with self._conn:
            self._conn.execute(
                "DELETE FROM user_permissions WHERE mxid=? AND key=?", (resolved, key)
            )

    def get_permissions(self, user: str) -> Optional[PermissionSet]:
        """Effective permission set for a username or MXID, or None if unknown."""
        mxid = self._resolve_mxid(user)
        if not mxid:
            return None
        row = self._conn.execute(
            "SELECT username, role, server_name FROM users WHERE mxid=?", (mxid,)
        ).fetchone()
        if row is None:
            return None
        role = str(row["role"])
        merged: Dict[str, Any] = dict(default_role_permissions().get(role, {}))
        for r in self._conn.execute(
            "SELECT key, value_json FROM role_permissions WHERE role=?", (role,)
        ):
            try:
                merged[r["key"]] = json.loads(r["value_json"])
            except json.JSONDecodeError:
                continue
        for r in self._conn.execute(
            "SELECT key, value_json FROM user_permissions WHERE mxid=?", (mxid,)
        ):
            try:
                merged[r["key"]] = json.loads(r["value_json"])
            except json.JSONDecodeError:
                continue
        ps = PermissionSet(
            mxid=mxid,
            username=str(row["username"] or (mxid[1:].split(":", 1)[0] if mxid.startswith("@") else mxid)),
            role=role,
            is_admin=self.role_is_admin(role),
        )
        for key, value in merged.items():
            if key in PERMISSION_KEYS:
                setattr(ps, key, _coerce(key, value))
        return ps

    def users_with_role(self, role: str) -> List[str]:
        rows = self._conn.execute(
            "SELECT mxid FROM users WHERE role=? ORDER BY mxid", (role.strip().lower(),)
        ).fetchall()
        return [str(r["mxid"]) for r in rows]

    def usernames_with_role(self, role: str) -> Set[str]:
        rows = self._conn.execute(
            "SELECT username, mxid FROM users WHERE role=?", (role.strip().lower(),)
        ).fetchall()
        out: Set[str] = set()
        for r in rows:
            name = r["username"] or (
                str(r["mxid"])[1:].split(":", 1)[0] if str(r["mxid"]).startswith("@") else None
            )
            if name:
                out.add(str(name))
        return out

    def enabled_event_usernames(self) -> Set[str]:
        """Kid usernames whose effective events_enabled is true (Mobilizon gate)."""
        out: Set[str] = set()
        for mxid in self.users_with_role("kid"):
            ps = self.get_permissions(mxid)
            if ps and ps.events_enabled and ps.username:
                out.add(ps.username)
        return out

    # ------------------------------------------------------ policy interop

    def to_policy_dict(self) -> Dict[str, Any]:
        """Render the DB in the family-policy.json shape for FamilyPolicy.from_dict."""
        kids: Dict[str, Any] = {}
        parents: List[str] = []
        rows = self._conn.execute("SELECT mxid, role FROM users ORDER BY mxid").fetchall()
        seen_admins: Dict[str, bool] = {}
        for r in rows:
            role = str(r["role"])
            if role not in seen_admins:
                seen_admins[role] = self.role_is_admin(role)
            ps = self.get_permissions(str(r["mxid"]))
            if ps is None:
                continue
            if seen_admins[role]:
                parents.append(ps.mxid)
                continue
            entry: Dict[str, Any] = {
                "allowlist_mxids": sorted(ps.allowlist_mxids),
                "allowlist_domains": sorted(ps.allowlist_domains),
                "events_enabled": ps.events_enabled,
            }
            if ps.quiet_hours:
                entry["quiet_hours"] = ps.quiet_hours.to_dict()
            kids[ps.mxid] = entry
        return {
            "server_name": self.server_name,
            "parent_mxids": sorted(set(parents)),
            "trusted_domains": sorted(self.trusted_domains),
            "reject_encryption": self.reject_encryption,
            "kids": kids,
        }

    # ---------------------------------------------------- seed from legacy json

    def import_legacy_policy(self, policy: Dict[str, Any]) -> None:
        """Idempotently import a family-policy.json dict as users + overrides.

        Existing per-user overrides are kept (DB is runtime state; re-seeding
        the same household is a no-op unless the JSON changed).
        """
        server = str(policy.get("server_name") or "").strip()
        if server:
            self.set_server_name(server)
        self.trusted_domains = policy.get("trusted_domains") or []
        if "reject_encryption" in policy:
            self.reject_encryption = bool(policy.get("reject_encryption"))
        for mxid in policy.get("parent_mxids") or []:
            if str(mxid).strip():
                self.set_role(str(mxid).strip(), "parent", server_name=server or None)
        kids = policy.get("kids") or {}
        for mxid, entry in kids.items():
            mxid = str(mxid).strip()
            if not mxid:
                continue
            self.set_role(mxid, "kid", server_name=server or None)
            if not isinstance(entry, dict):
                continue
            for key in LIST_KEYS:
                if key in entry:
                    self.set_permission(mxid, key, entry.get(key) or [])
            if "events_enabled" in entry:
                self.set_permission(mxid, "events_enabled", bool(entry.get("events_enabled")))
            if entry.get("quiet_hours"):
                self.set_permission(mxid, "quiet_hours", entry["quiet_hours"])

    def import_legacy_policy_file(self, path: str | Path) -> None:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("policy JSON root must be an object")
        self.import_legacy_policy(data)

    LEGACY_POLICY_IMPORTED_KEY = "legacy_policy_imported"

    def household_is_seeded(self) -> bool:
        row = self._conn.execute("SELECT COUNT(*) AS n FROM users").fetchone()
        return bool(row and int(row["n"]) > 0)

    def legacy_policy_was_imported(self) -> bool:
        return bool(self.get_meta(self.LEGACY_POLICY_IMPORTED_KEY, False))

    def should_import_legacy_policy(self) -> bool:
        """One-time migration from family-policy.json when the DB has no household yet."""
        if self.legacy_policy_was_imported() or self.household_is_seeded():
            return False
        return True

    def mark_legacy_policy_imported(self) -> None:
        self.set_meta(self.LEGACY_POLICY_IMPORTED_KEY, True)

    # -------------------------------------------------------------- backup

    def export_dict(self) -> Dict[str, Any]:
        """Full store dump for backup (JSON-serialisable)."""
        def rows(sql: str) -> List[Dict[str, Any]]:
            return [dict(r) for r in self._conn.execute(sql)]

        out: Dict[str, Any] = {"schema_version": SCHEMA_VERSION}
        out["meta"] = {
            r["key"]: json.loads(r["value"]) for r in self._conn.execute("SELECT key, value FROM meta")
        }
        out["roles"] = rows("SELECT name, is_admin FROM roles ORDER BY name")
        role_perms: Dict[str, Dict[str, Any]] = {}
        for r in self._conn.execute("SELECT role, key, value_json FROM role_permissions"):
            role_perms.setdefault(str(r["role"]), {})[str(r["key"])] = json.loads(r["value_json"])
        out["role_permissions"] = role_perms
        out["users"] = rows("SELECT mxid, username, role, server_name FROM users ORDER BY mxid")
        user_perms: Dict[str, Dict[str, Any]] = {}
        for r in self._conn.execute("SELECT mxid, key, value_json FROM user_permissions"):
            user_perms.setdefault(str(r["mxid"]), {})[str(r["key"])] = json.loads(r["value_json"])
        out["user_permissions"] = user_perms
        return out

    def import_dict(self, data: Dict[str, Any]) -> None:
        """Restore an export_dict() dump (roles first to satisfy FKs)."""
        if not isinstance(data, dict):
            raise ValueError("export payload must be an object")
        with self._conn:
            self._conn.execute("DELETE FROM user_permissions")
            self._conn.execute("DELETE FROM users")
            self._conn.execute("DELETE FROM role_permissions")
            self._conn.execute("DELETE FROM roles")
            self._conn.execute("DELETE FROM meta")
            for key, value in (data.get("meta") or {}).items():
                self._conn.execute(
                    "INSERT INTO meta(key, value) VALUES(?,?)", (key, json.dumps(value))
                )
            self._conn.execute(
                "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)",
                (str(SCHEMA_VERSION),),
            )
            for role in data.get("roles") or []:
                self._conn.execute(
                    "INSERT INTO roles(name, is_admin) VALUES(?,?)",
                    (str(role["name"]), 1 if role.get("is_admin") else 0),
                )
            for role, perms in (data.get("role_permissions") or {}).items():
                for key, value in perms.items():
                    self._conn.execute(
                        "INSERT INTO role_permissions(role, key, value_json) VALUES(?,?,?)",
                        (str(role), str(key), json.dumps(value)),
                    )
            for user in data.get("users") or []:
                self._conn.execute(
                    "INSERT INTO users(mxid, username, role, server_name) VALUES(?,?,?,?)",
                    (
                        str(user["mxid"]),
                        user.get("username"),
                        str(user["role"]),
                        user.get("server_name"),
                    ),
                )
            for mxid, perms in (data.get("user_permissions") or {}).items():
                for key, value in perms.items():
                    self._conn.execute(
                        "INSERT INTO user_permissions(mxid, key, value_json) VALUES(?,?,?)",
                        (str(mxid), str(key), json.dumps(value)),
                    )


def _canonical_value(key: str, value: Any) -> Any:
    if key in BOOL_KEYS:
        return bool(value)
    if key in STR_KEYS:
        return str(value)
    if key in LIST_KEYS:
        if value is None:
            return []
        if isinstance(value, (list, tuple, set)):
            return sorted({str(v).strip() for v in value if str(v).strip()})
        raise ValueError(f"{key} expects a list of strings")
    if key == "quiet_hours":
        if value is None:
            return None
        if not isinstance(value, dict):
            raise ValueError("quiet_hours expects an object or null")
        qh = QuietHours.from_dict(value)
        if qh is None:
            raise ValueError("quiet_hours requires start and end")
        return qh.to_dict()
    raise ValueError(f"Unknown permission key: {key}")


def default_role_seed_dir() -> Path:
    return Path(__file__).resolve().parent / "roles"


def default_role_seed_files() -> Tuple[Path, Path]:
    d = default_role_seed_dir()
    return (d / "parent.yaml", d / "kid.yaml")


class SqliteFamilyPolicyStore:
    """PolicyStore-compatible reader: SQLite when seeded, JSON file otherwise.

    Mirrors tinywebstack_family.policy.PolicyStore (``.policy`` property +
    ``reload_if_changed``) so the Synapse module keeps cached-object semantics
    (tests pin ``store.policy.kid_in_quiet_hours``). The DB is consulted on
    every access; a missing DB file falls back to the JSON file store.
    """

    def __init__(self, policy_path: str | Path, db_path: Optional[Path] = None,
                 config: Optional[Dict[str, Any]] = None) -> None:
        from tinywebstack_family.policy import PolicyStore  # deferred: synapse-side import

        self._file_store = PolicyStore(policy_path)
        self._config = config
        self._explicit_db_path = Path(db_path) if db_path is not None else None
        self._stamp: Tuple[Any, ...] = ("none", 0, 0)
        self._db_policy: Any = None

    def _db_path(self) -> Optional[Path]:
        if self._explicit_db_path is not None:
            return self._explicit_db_path if self._explicit_db_path.is_file() else None
        return resolve_db_path(self._config, require_existing=True)

    @property
    def policy(self) -> Any:
        self.reload_if_changed()
        return self._db_policy if self._db_policy is not None else self._file_store.policy

    @policy.setter
    def policy(self, value: Any) -> None:  # parity with PolicyStore internals
        self._file_store._policy = value

    def reload_if_changed(self) -> None:
        db = self._db_path()
        if db is None:
            self._db_policy = None
            self._stamp = ("none", 0, 0)
            self._file_store.reload_if_changed()
            return
        try:
            st = db.stat()
            stamp: Tuple[Any, ...] = ("db", int(st.st_mtime_ns), int(st.st_size))
        except OSError as exc:
            log.error("Cannot stat permissions DB %s: %s — using JSON policy", db, exc)
            self._db_policy = None
            self._file_store.reload_if_changed()
            return
        if stamp == self._stamp and self._db_policy is not None:
            return
        try:
            from tinywebstack_family.policy import FamilyPolicy

            with PermissionsDB.open_readonly(db) as pdb:
                self._db_policy = FamilyPolicy.from_dict(pdb.to_policy_dict())
            self._stamp = stamp
            log.info("Loaded family permissions from SQLite DB %s", db)
        except ImportError:
            log.error(
                "tinywebstack_permissions not importable but DB %s exists — "
                "falling back to JSON policy",
                db,
            )
            self._db_policy = None
            self._file_store.reload_if_changed()
        except Exception as exc:
            log.error("Invalid permissions DB %s: %s — failing closed for kids", db, exc)
            from tinywebstack_family.policy import FamilyPolicy

            self._db_policy = FamilyPolicy.fail_closed()
            self._stamp = stamp
