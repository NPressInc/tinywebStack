"""Dashboard URL prefix behind nginx (/family/)."""

from __future__ import annotations

import os
from urllib.parse import urlparse


def dashboard_root_path() -> str:
    explicit = os.environ.get("TWS_DASHBOARD_ROOT_PATH", "").strip()
    if explicit:
        return explicit if explicit.startswith("/") else f"/{explicit}"
    pub = os.environ.get("TWS_PUBLIC_BASE_URL", "").strip()
    if pub:
        path = urlparse(pub).path.rstrip("/")
        if path:
            return path
    return "/family"


def dash_url(path: str, root: str | None = None) -> str:
    query = ""
    if "?" in path:
        path, query = path.split("?", 1)
        query = f"?{query}"
    base = (root or dashboard_root_path()).rstrip("/")
    if not path or path == "/":
        joined = f"{base}/"
    else:
        if not path.startswith("/"):
            path = f"/{path}"
        joined = f"{base}{path}"
    return f"{joined}{query}"
