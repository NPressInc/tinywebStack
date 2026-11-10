"""SQLite state for units, slugs, and tunnel credentials.

The database holds tunnel tokens and, until setup is marked complete, the
claim token needed to retry a lost response. Create it mode 0600. Do not
commit the file.
"""

from __future__ import annotations

import os
import sqlite3
import threading
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS units (
  unit_id TEXT PRIMARY KEY,
  setup_code_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  claimed_at TEXT,
  setup_completed_at TEXT,
  slug TEXT,
  claim_token_hash TEXT,
  claim_token_pending TEXT
);

CREATE TABLE IF NOT EXISTS slugs (
  slug TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL,
  domain TEXT NOT NULL,
  reserved_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tunnels (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  unit_id TEXT NOT NULL,
  slug TEXT NOT NULL,
  cf_tunnel_id TEXT NOT NULL,
  account_tag TEXT NOT NULL,
  token TEXT NOT NULL,
  credentials_json TEXT NOT NULL,
  status TEXT NOT NULL,
  published INTEGER NOT NULL,
  provider TEXT NOT NULL,
  dns_json TEXT NOT NULL,
  cert_json TEXT NOT NULL,
  excluded_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);
"""


class Store:
    def __init__(self, path: str | os.PathLike[str]) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
            os.close(fd)
        os.chmod(self.path, 0o600)
        self._conn = sqlite3.connect(
            self.path,
            timeout=5,
            check_same_thread=False,
            isolation_level=None,
        )
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA busy_timeout=5000")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._lock = threading.RLock()
        self.migrate()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def migrate(self) -> None:
        with self._lock:
            self._conn.executescript(SCHEMA)

    def create_unit(self, *, unit_id: str, setup_code_hash: str, created_at: str) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO units (unit_id, setup_code_hash, created_at) VALUES (?, ?, ?)",
                (unit_id, setup_code_hash, created_at),
            )

    def slug_row(self, slug: str) -> sqlite3.Row | None:
        with self._lock:
            return self._conn.execute("SELECT * FROM slugs WHERE slug = ?", (slug,)).fetchone()

    def claim(
        self,
        *,
        setup_code_hash: str,
        slug: str,
        domain: str,
        new_claim_token: str,
        new_claim_token_hash: str,
        now: str,
    ) -> dict[str, Any]:
        """Bind a setup code to a slug, or replay the in-progress claim.

        The setup code keeps working until setup is marked complete. A second
        family cannot take the slug. After complete, the code cannot take over.
        """
        with self._lock:
            self._conn.execute("BEGIN IMMEDIATE")
            try:
                result = self._claim_locked(
                    setup_code_hash=setup_code_hash,
                    slug=slug,
                    domain=domain,
                    new_claim_token=new_claim_token,
                    new_claim_token_hash=new_claim_token_hash,
                    now=now,
                )
                self._conn.execute("COMMIT")
                return result
            except Exception:
                self._conn.execute("ROLLBACK")
                raise

    def _claim_locked(
        self,
        *,
        setup_code_hash: str,
        slug: str,
        domain: str,
        new_claim_token: str,
        new_claim_token_hash: str,
        now: str,
    ) -> dict[str, Any]:
        unit = self._conn.execute(
            "SELECT * FROM units WHERE setup_code_hash = ?",
            (setup_code_hash,),
        ).fetchone()
        if unit is None:
            return {"kind": "unknown_code"}
        if unit["setup_completed_at"]:
            return {
                "kind": "already_complete",
                "slug": unit["slug"],
                "unit_id": unit["unit_id"],
            }
        if unit["claimed_at"]:
            if unit["slug"] != slug:
                return {
                    "kind": "slug_mismatch",
                    "slug": unit["slug"],
                    "unit_id": unit["unit_id"],
                }
            pending = unit["claim_token_pending"]
            if not pending:
                return {
                    "kind": "claim_token_unavailable",
                    "slug": unit["slug"],
                    "unit_id": unit["unit_id"],
                }
            return {
                "kind": "replay",
                "slug": unit["slug"],
                "unit_id": unit["unit_id"],
                "claim_token": pending,
            }
        taken = self._conn.execute("SELECT unit_id FROM slugs WHERE slug = ?", (slug,)).fetchone()
        if taken is not None:
            return {"kind": "slug_taken", "slug": slug}
        try:
            self._conn.execute(
                "INSERT INTO slugs (slug, unit_id, domain, reserved_at) VALUES (?, ?, ?, ?)",
                (slug, unit["unit_id"], domain, now),
            )
        except sqlite3.IntegrityError:
            return {"kind": "slug_taken", "slug": slug}
        self._conn.execute(
            """
            UPDATE units
               SET claimed_at = ?, slug = ?, claim_token_hash = ?, claim_token_pending = ?
             WHERE unit_id = ?
            """,
            (now, slug, new_claim_token_hash, new_claim_token, unit["unit_id"]),
        )
        return {
            "kind": "created",
            "slug": slug,
            "unit_id": unit["unit_id"],
            "claim_token": new_claim_token,
        }

    def unit_by_id(self, unit_id: str) -> sqlite3.Row | None:
        with self._lock:
            return self._conn.execute("SELECT * FROM units WHERE unit_id = ?", (unit_id,)).fetchone()

    def unit_by_claim_hash(self, claim_token_hash: str) -> sqlite3.Row | None:
        with self._lock:
            return self._conn.execute(
                "SELECT * FROM units WHERE claim_token_hash = ?",
                (claim_token_hash,),
            ).fetchone()

    def complete(self, claim_token_hash: str, now: str) -> dict[str, Any]:
        with self._lock:
            self._conn.execute("BEGIN IMMEDIATE")
            try:
                unit = self._conn.execute(
                    "SELECT * FROM units WHERE claim_token_hash = ?",
                    (claim_token_hash,),
                ).fetchone()
                if unit is None:
                    result: dict[str, Any] = {"kind": "unknown_token"}
                elif unit["setup_completed_at"]:
                    result = {
                        "kind": "already_complete",
                        "slug": unit["slug"],
                        "unit_id": unit["unit_id"],
                    }
                else:
                    self._conn.execute(
                        """
                        UPDATE units
                           SET setup_completed_at = ?, claim_token_pending = NULL
                         WHERE unit_id = ?
                        """,
                        (now, unit["unit_id"]),
                    )
                    result = {
                        "kind": "completed",
                        "slug": unit["slug"],
                        "unit_id": unit["unit_id"],
                    }
                self._conn.execute("COMMIT")
            except Exception:
                self._conn.execute("ROLLBACK")
                raise
            if result.get("kind") == "completed":
                # Drop the freed page that held the claim token plaintext.
                try:
                    self._conn.execute("VACUUM")
                except sqlite3.Error:
                    pass
            return result

    def save_tunnel(
        self,
        *,
        unit_id: str,
        slug: str,
        cf_tunnel_id: str,
        account_tag: str,
        token: str,
        credentials_json: str,
        published: bool,
        provider: str,
        dns_json: str,
        cert_json: str,
        excluded_json: str,
        created_at: str,
    ) -> None:
        with self._lock:
            self._conn.execute(
                """
                INSERT INTO tunnels (
                  unit_id, slug, cf_tunnel_id, account_tag, token, credentials_json,
                  status, published, provider, dns_json, cert_json, excluded_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?)
                """,
                (
                    unit_id,
                    slug,
                    cf_tunnel_id,
                    account_tag,
                    token,
                    credentials_json,
                    1 if published else 0,
                    provider,
                    dns_json,
                    cert_json,
                    excluded_json,
                    created_at,
                ),
            )

    def update_tunnel_cert(self, tunnel_row_id: int, cert_json: str) -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE tunnels SET cert_json = ? WHERE id = ?",
                (cert_json, tunnel_row_id),
            )

    def active_tunnel(self, unit_id: str) -> sqlite3.Row | None:
        with self._lock:
            return self._conn.execute(
                """
                SELECT * FROM tunnels
                 WHERE unit_id = ? AND status = 'active'
                 ORDER BY id DESC LIMIT 1
                """,
                (unit_id,),
            ).fetchone()

    def revoke_active(self, unit_id: str, now: str) -> sqlite3.Row | None:
        with self._lock:
            self._conn.execute("BEGIN IMMEDIATE")
            try:
                row = self._conn.execute(
                    """
                    SELECT * FROM tunnels
                     WHERE unit_id = ? AND status = 'active'
                     ORDER BY id DESC LIMIT 1
                    """,
                    (unit_id,),
                ).fetchone()
                if row is not None:
                    self._conn.execute(
                        "UPDATE tunnels SET status = 'revoked', revoked_at = ? WHERE id = ?",
                        (now, row["id"]),
                    )
                self._conn.execute("COMMIT")
                return row
            except Exception:
                self._conn.execute("ROLLBACK")
                raise
