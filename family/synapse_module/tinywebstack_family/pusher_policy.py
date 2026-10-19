"""Matrix HTTP pusher policy: event_id_only payloads (no message content)."""

from __future__ import annotations

from typing import Any, Dict, Mapping, Tuple


REQUIRED_FORMAT = "event_id_only"


def normalize_http_pusher_data(data: Mapping[str, Any] | None) -> Dict[str, Any]:
    """Force event_id_only on HTTP pusher data (used by app + documented for operators)."""
    out: Dict[str, Any] = dict(data or {})
    out["format"] = REQUIRED_FORMAT
    return out


def validate_http_pusher_registration(
    app_id: str,
    pushkey: str,
    data: Mapping[str, Any] | None,
) -> Tuple[bool, str]:
    if not app_id or not pushkey:
        return False, "app_id and pushkey are required"
    if not isinstance(data, Mapping):
        return False, "HTTP pusher requires data.url"
    url = data.get("url")
    if not isinstance(url, str) or not url.strip():
        return False, "HTTP pusher requires data.url"
    fmt = data.get("format")
    if fmt is not None and fmt != REQUIRED_FORMAT:
        return False, f"pushers must use data.format={REQUIRED_FORMAT}"
    return True, ""


def synapse_event_id_only_content(
    event_id: str,
    room_id: str,
    badge: int,
    priority: str = "high",
) -> Dict[str, Any]:
    """Mirror Synapse HttpPusher event_id_only notification content (for tests)."""
    return {
        "event_id": event_id,
        "room_id": room_id,
        "prio": priority,
        "counts": {"unread": badge},
    }
