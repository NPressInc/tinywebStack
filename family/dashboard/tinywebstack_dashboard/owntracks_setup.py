"""OwnTracks HTTP mode configuration + QR payload for kids."""

from __future__ import annotations

import base64
import json
from typing import Any, Dict


def build_owntracks_config(
    publish_url: str,
    username: str,
    password: str,
    device_id: str,
    tracker_id: str,
) -> Dict[str, Any]:
    return {
        "_type": "configuration",
        "mode": 3,
        "url": publish_url.rstrip("/") + "/",
        "username": username,
        "password": password,
        "deviceId": device_id,
        "tid": tracker_id[:2].ljust(2, "0")[:2],
        "locatorInterval": 900,
        "locatorDisplacement": 200,
        "monitoring": 1,
        "encryptionKey": "",
        "extendedData": True,
    }


def owntracks_config_json(cfg: Dict[str, Any]) -> str:
    return json.dumps(cfg, separators=(",", ":"))


def owntracks_otcp_link(cfg: Dict[str, Any]) -> str:
    """Base64url-encoded configuration (OwnTracks import format)."""
    raw = owntracks_config_json(cfg).encode("utf-8")
    b64 = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
    return f"owntracks:///config?c={b64}"


def load_stored_credentials(store_path: str, username: str) -> Dict[str, str] | None:
    from pathlib import Path

    p = Path(store_path)
    if not p.is_file():
        return None
    data = json.loads(p.read_text(encoding="utf-8"))
    entry = data.get(username)
    return entry if isinstance(entry, dict) else None
