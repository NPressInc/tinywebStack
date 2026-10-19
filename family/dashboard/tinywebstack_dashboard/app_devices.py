"""SQLite store for TinyWeb app device tokens and enrollment codes."""

from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import sqlite3
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional

_CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
_TOKEN_PREFIX = "tws_"


def _db_path() -> Path:
    return Path(os.environ.get("TWS_APP_DEVICES_DB", "/etc/tinywebstack/app-devices.db"))


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _hash_secret(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _code_ttl_s() -> int:
    return int(os.environ.get("TWS_APP_CODE_TTL_S", "600"))


def init_db(path: Path | None = None) -> None:
    path = path or _db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS devices (
                id TEXT PRIMARY KEY,
                username TEXT NOT NULL,
                role TEXT NOT NULL,
                device_name TEXT NOT NULL,
                platform TEXT NOT NULL,
                created_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                revoked_at TEXT,
                token_hash TEXT NOT NULL,
                matrix_device_id TEXT,
                nextcloud_token_name TEXT,
                nextcloud_token_id TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_devices_username ON devices(username);

            CREATE TABLE IF NOT EXISTS enroll_codes (
                code_hash TEXT PRIMARY KEY,
                username TEXT NOT NULL,
                created_by TEXT NOT NULL,
                created_at TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                used_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_enroll_codes_user ON enroll_codes(username);

            CREATE TABLE IF NOT EXISTS enroll_attempts (
                key TEXT NOT NULL,
                ts REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_enroll_attempts_key_ts ON enroll_attempts(key, ts);
            """
        )
        cols = {row[1] for row in conn.execute("PRAGMA table_info(devices)").fetchall()}
        if "nextcloud_token_id" not in cols:
            conn.execute("ALTER TABLE devices ADD COLUMN nextcloud_token_id TEXT")
        conn.commit()
    try:
        path.chmod(0o600)
    except OSError:
        pass


@contextmanager
def _connect(path: Path | None = None) -> Iterator[sqlite3.Connection]:
    path = path or _db_path()
    init_db(path)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def generate_enroll_code() -> str:
    return "".join(secrets.choice(_CODE_ALPHABET) for _ in range(8))


def create_enroll_code(username: str, created_by: str) -> tuple[str, str]:
    """Return (plaintext code, expires_at ISO)."""
    code = generate_enroll_code()
    expires = datetime.now(timezone.utc).timestamp() + _code_ttl_s()
    expires_at = datetime.fromtimestamp(expires, tz=timezone.utc).replace(microsecond=0).isoformat()
    with _connect() as conn:
        conn.execute(
            """
            INSERT INTO enroll_codes (code_hash, username, created_by, created_at, expires_at, used_at)
            VALUES (?, ?, ?, ?, ?, NULL)
            """,
            (_hash_secret(code), username, created_by, _now_iso(), expires_at),
        )
    return code, expires_at


def consume_enroll_code(code: str) -> Optional[str]:
    """Validate code; mark used. Return username or None."""
    ch = _hash_secret(code.strip().upper())
    now = _now_iso()
    with _connect() as conn:
        row = conn.execute(
            "SELECT username, expires_at, used_at FROM enroll_codes WHERE code_hash = ?",
            (ch,),
        ).fetchone()
        if not row:
            return None
        if row["used_at"]:
            return None
        exp = row["expires_at"]
        if exp and exp < now:
            return None
        conn.execute(
            "UPDATE enroll_codes SET used_at = ? WHERE code_hash = ?",
            (now, ch),
        )
        return str(row["username"])


def mint_device_token() -> str:
    return _TOKEN_PREFIX + secrets.token_urlsafe(32)


def verify_token(token: str) -> Optional[str]:
    """Return device id if token valid and not revoked."""
    if not token.startswith(_TOKEN_PREFIX):
        return None
    th = _hash_secret(token)
    with _connect() as conn:
        row = conn.execute(
            """
            SELECT id FROM devices
            WHERE token_hash = ? AND revoked_at IS NULL
            """,
            (th,),
        ).fetchone()
        if not row:
            return None
        device_id = str(row["id"])
        conn.execute(
            "UPDATE devices SET last_seen_at = ? WHERE id = ?",
            (_now_iso(), device_id),
        )
        return device_id


def token_matches_stored(token: str, stored_hash: str) -> bool:
    return hmac.compare_digest(_hash_secret(token), stored_hash)


@dataclass
class DeviceRow:
    id: str
    username: str
    role: str
    device_name: str
    platform: str
    created_at: str
    last_seen_at: str
    revoked_at: Optional[str]
    matrix_device_id: Optional[str]
    nextcloud_token_name: Optional[str]
    nextcloud_token_id: Optional[str]

    def to_public_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "username": self.username,
            "role": self.role,
            "device_name": self.device_name,
            "platform": self.platform,
            "created_at": self.created_at,
            "last_seen_at": self.last_seen_at,
            "revoked_at": self.revoked_at,
            "matrix_device_id": self.matrix_device_id,
            "nextcloud_token_name": self.nextcloud_token_name,
        }


def _row_to_device(row: sqlite3.Row) -> DeviceRow:
    return DeviceRow(
        id=str(row["id"]),
        username=str(row["username"]),
        role=str(row["role"]),
        device_name=str(row["device_name"]),
        platform=str(row["platform"]),
        created_at=str(row["created_at"]),
        last_seen_at=str(row["last_seen_at"]),
        revoked_at=row["revoked_at"],
        matrix_device_id=row["matrix_device_id"],
        nextcloud_token_name=row["nextcloud_token_name"],
        nextcloud_token_id=row["nextcloud_token_id"],
    )


def create_device(
    *,
    username: str,
    role: str,
    device_name: str,
    platform: str,
    token: str,
    matrix_device_id: Optional[str] = None,
    nextcloud_token_name: Optional[str] = None,
    nextcloud_token_id: Optional[str] = None,
) -> DeviceRow:
    device_id = secrets.token_hex(16)
    now = _now_iso()
    with _connect() as conn:
        conn.execute(
            """
            INSERT INTO devices (
                id, username, role, device_name, platform,
                created_at, last_seen_at, revoked_at, token_hash,
                matrix_device_id, nextcloud_token_name, nextcloud_token_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)
            """,
            (
                device_id,
                username,
                role,
                device_name,
                platform,
                now,
                now,
                _hash_secret(token),
                matrix_device_id,
                nextcloud_token_name,
                nextcloud_token_id,
            ),
        )
    return get_device(device_id)  # type: ignore[return-value]


def get_device(device_id: str) -> Optional[DeviceRow]:
    with _connect() as conn:
        row = conn.execute("SELECT * FROM devices WHERE id = ?", (device_id,)).fetchone()
        if not row:
            return None
        return _row_to_device(row)


def list_devices_for_user(username: str, include_revoked: bool = False) -> List[DeviceRow]:
    q = "SELECT * FROM devices WHERE username = ?"
    if not include_revoked:
        q += " AND revoked_at IS NULL"
    q += " ORDER BY created_at DESC"
    with _connect() as conn:
        rows = conn.execute(q, (username,)).fetchall()
    return [_row_to_device(r) for r in rows]


def list_all_devices(include_revoked: bool = False) -> List[DeviceRow]:
    q = "SELECT * FROM devices"
    if not include_revoked:
        q += " WHERE revoked_at IS NULL"
    q += " ORDER BY username, created_at DESC"
    with _connect() as conn:
        rows = conn.execute(q).fetchall()
    return [_row_to_device(r) for r in rows]


def count_devices_for_user(username: str) -> int:
    with _connect() as conn:
        row = conn.execute(
            "SELECT COUNT(*) AS n FROM devices WHERE username = ? AND revoked_at IS NULL",
            (username,),
        ).fetchone()
    return int(row["n"]) if row else 0


def revoke_device(device_id: str) -> Optional[DeviceRow]:
    now = _now_iso()
    with _connect() as conn:
        row = conn.execute("SELECT * FROM devices WHERE id = ?", (device_id,)).fetchone()
        if not row or row["revoked_at"]:
            return None
        conn.execute("UPDATE devices SET revoked_at = ? WHERE id = ?", (now, device_id))
    return get_device(device_id)


def revoke_all_for_user(username: str) -> List[DeviceRow]:
    now = _now_iso()
    with _connect() as conn:
        conn.execute(
            "UPDATE devices SET revoked_at = ? WHERE username = ? AND revoked_at IS NULL",
            (now, username),
        )
        rows = conn.execute(
            "SELECT * FROM devices WHERE username = ? AND revoked_at = ?",
            (username, now),
        ).fetchall()
    return [_row_to_device(r) for r in rows]


_ENROLL_WINDOW_S = 15 * 60
_ENROLL_MAX_FAILS = 5


def _enroll_rate_keys(client_key: str, username: str) -> list[str]:
    keys = [f"user:{username}"]
    if client_key not in ("unknown", "127.0.0.1", "::1"):
        keys.append(f"ip:{client_key}")
    return keys


def record_enroll_failure(client_key: str, username: str) -> None:
    now = time.time()
    with _connect() as conn:
        for key in _enroll_rate_keys(client_key, username):
            conn.execute("INSERT INTO enroll_attempts (key, ts) VALUES (?, ?)", (key, now))


def enroll_rate_limited(client_key: str, username: str) -> bool:
    cutoff = time.time() - _ENROLL_WINDOW_S
    with _connect() as conn:
        conn.execute("DELETE FROM enroll_attempts WHERE ts < ?", (cutoff,))
        for key in _enroll_rate_keys(client_key, username):
            row = conn.execute(
                "SELECT COUNT(*) AS n FROM enroll_attempts WHERE key = ? AND ts >= ?",
                (key, cutoff),
            ).fetchone()
            if row and int(row["n"]) >= _ENROLL_MAX_FAILS:
                return True
    return False


def clear_enroll_failures(client_key: str, username: str) -> None:
    with _connect() as conn:
        for key in _enroll_rate_keys(client_key, username):
            conn.execute("DELETE FROM enroll_attempts WHERE key = ?", (key,))
