"""Read-only HTTP client for OwnTracks Recorder API (localhost on the box)."""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_API_URL = "http://127.0.0.1:25959"
RECORDER_TIMEOUT_S = 3.0
TRACK_POINT_CAP = 2000


def api_base_url() -> str:
    return os.environ.get("TWS_OWNTRACKS_API_URL", DEFAULT_API_URL).rstrip("/")


def _dict_rows(data: Any) -> List[Dict[str, Any]]:
    if not isinstance(data, list):
        raise ValueError("expected JSON array from Recorder")
    return [item for item in data if isinstance(item, dict)]


def _get_json(path: str, query: Optional[Dict[str, str]] = None) -> Any:
    base = api_base_url()
    url = f"{base}{path}"
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=RECORDER_TIMEOUT_S) as resp:
        raw = resp.read().decode("utf-8")
    return json.loads(raw)


def fetch_all_last() -> Tuple[Optional[List[Dict[str, Any]]], bool]:
    """Return (rows, ok). On failure rows is None and ok is False."""
    try:
        return _dict_rows(_get_json("/api/0/last")), True
    except (urllib.error.URLError, OSError, ValueError, json.JSONDecodeError, urllib.error.HTTPError):
        return None, False


def fetch_track(
    username: str,
    device: str,
    hours: int,
) -> Tuple[Optional[List[Dict[str, Any]]], bool]:
    hours = max(1, min(hours, 168))
    now = int(time.time())
    from_ts = now - hours * 3600
    query = {
        "user": username,
        "device": device,
        # ot-recorder expects ISO-8601 UTC (YYYY-MM-DDTHH:MM:SS), not epoch seconds.
        "from": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(from_ts)),
        "to": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)),
        "limit": str(TRACK_POINT_CAP),
    }
    try:
        raw = _get_json("/api/0/locations", query)
        # ot-recorder answers {"count": N, "data": [...]}; accept a bare list too.
        rows = _dict_rows(raw.get("data", []) if isinstance(raw, dict) else raw)
        if len(rows) > TRACK_POINT_CAP:
            rows = rows[:TRACK_POINT_CAP]
        return rows, True
    except (urllib.error.URLError, OSError, ValueError, json.JSONDecodeError, urllib.error.HTTPError):
        return None, False


def _position_fields(row: Dict[str, Any]) -> Dict[str, Any]:
    tst = row.get("tst")
    age: Optional[int] = None
    if isinstance(tst, (int, float)):
        age = max(0, int(time.time()) - int(tst))
    out: Dict[str, Any] = {
        "lat": row.get("lat"),
        "lon": row.get("lon"),
        "acc": row.get("acc"),
        "batt": row.get("batt"),
        "tst": tst,
        "age_seconds": age,
    }
    tid = row.get("tid")
    if tid is not None:
        out["tid"] = tid
    return out


def latest_per_kid(
    kid_usernames: List[str],
    last_rows: List[Dict[str, Any]],
    tid_by_user: Dict[str, str],
) -> List[Dict[str, Any]]:
    """Merge Recorder /last rows into one entry per kid (newest tst wins)."""
    kid_set = set(kid_usernames)
    best: Dict[str, Dict[str, Any]] = {}
    for row in last_rows:
        user = str(row.get("username") or "").strip().lower()
        if user not in kid_set:
            continue
        tst = row.get("tst")
        if not isinstance(tst, (int, float)):
            continue
        prev = best.get(user)
        if prev is None or int(tst) > int(prev.get("tst") or 0):
            best[user] = row

    kids_out: List[Dict[str, Any]] = []
    for username in sorted(kid_usernames):
        entry: Dict[str, Any] = {
            "username": username,
            "display_name": username,
            "tid": tid_by_user.get(username, ""),
        }
        row = best.get(username)
        if row:
            pos = _position_fields(row)
            entry.update(pos)
            if not entry.get("tid") and pos.get("tid"):
                entry["tid"] = pos["tid"]
        else:
            entry.update(
                {
                    "lat": None,
                    "lon": None,
                    "acc": None,
                    "batt": None,
                    "tst": None,
                    "age_seconds": None,
                }
            )
        kids_out.append(entry)
    return kids_out


def track_points(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    points: List[Dict[str, Any]] = []
    for row in rows:
        if row.get("_type") != "location" and row.get("lat") is None:
            continue
        pt: Dict[str, Any] = {
            "lat": row.get("lat"),
            "lon": row.get("lon"),
            "tst": row.get("tst"),
        }
        if row.get("acc") is not None:
            pt["acc"] = row.get("acc")
        if row.get("batt") is not None:
            pt["batt"] = row.get("batt")
        if row.get("tid") is not None:
            pt["tid"] = row.get("tid")
        points.append(pt)
    return points[:TRACK_POINT_CAP]
