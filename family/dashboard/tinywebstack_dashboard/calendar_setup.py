"""CalDAV phone setup helpers (DAVx5 / iOS)."""

from __future__ import annotations

from urllib.parse import quote


def caldav_account_url(caldav_root: str, username: str) -> str:
    root = caldav_root.rstrip("/")
    return f"{root}/principals/users/{quote(username)}/"


def davx5_login_hint(caldav_root: str, username: str) -> str:
    """Plain-language steps encoded as a single import-friendly string for QR."""
    return (
        f"TinyWeb CalDAV\nURL: {caldav_root.rstrip('/')}\n"
        f"Username: {username}\n"
        "Use your family password (parents can reset kid passwords in the dashboard)."
    )
