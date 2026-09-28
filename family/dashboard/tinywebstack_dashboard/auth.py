"""YunoHost SSO header auth and LDAP group checks."""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from typing import List, Optional


@dataclass
class DashboardConfig:
    parents_group: str = "parents"
    kids_group: str = "kids"
    policy_path: str = "/etc/tinywebstack/family-policy.json"
    server_name: str = ""
    location_base_url: str = ""
    location_domain: str = ""
    events_base_url: str = ""
    caldav_root: str = ""
    csrf_secret: str = ""
    yunohost_cli: str = "yunohost"
    owntracks_store_path: str = "/etc/tinywebstack/owntracks-kids.json"


def username_from_headers(headers: dict) -> Optional[str]:
    """Trust only YNH_USER set by SSOwat (nginx must clear Remote-User)."""
    val = headers.get("YNH_USER") or headers.get("ynh_user")
    if val:
        return str(val).strip().split("@")[0]
    return None


def _helper_cmd() -> list[str]:
    path = os.environ.get(
        "TWS_YUNOHOST_PRIV_HELPER",
        "sudo /usr/local/sbin/tws-family-dashboard-privileged",
    )
    return path.split()


def _fetch_users_payload() -> dict:
    if os.environ.get("TWS_DASHBOARD_MOCK_GROUPS"):
        raw = os.environ.get("TWS_DASHBOARD_MOCK_GROUPS", "{}")
        mapping = json.loads(raw)
        users = {}
        for group, names in mapping.items():
            for name in names:
                users.setdefault(name, {"groups": []})
                users[name]["groups"].append(group)
        return {"users": users}
    out = subprocess.check_output(
        [*_helper_cmd(), "list-users"],
        text=True,
        stderr=subprocess.STDOUT,
    )
    data = json.loads(out)
    try:
        from tinywebstack_family.yunohost_json import users_map

        return {"users": dict(users_map(data))}
    except ImportError:
        if "users" in data:
            return data
        return {"users": data}


def list_group_members(group: str, yunohost_cli: str = "yunohost") -> List[str]:
    del yunohost_cli  # list-users goes through sudo helper
    try:
        payload = _fetch_users_payload()
    except (subprocess.CalledProcessError, json.JSONDecodeError, FileNotFoundError):
        return []
    members: List[str] = []
    users = payload.get("users") or {}
    for name, info in users.items():
        groups = info.get("groups") or info.get("group") or []
        if isinstance(groups, dict):
            groups = list(groups.keys())
        if group in groups:
            members.append(name)
    return sorted(members)


def user_in_group(username: str, group: str, yunohost_cli: str = "yunohost") -> bool:
    return username in list_group_members(group, yunohost_cli)


def require_parent(username: Optional[str], cfg: DashboardConfig) -> None:
    from fastapi import HTTPException

    if not username:
        raise HTTPException(status_code=401, detail="SSO login required")
    if not user_in_group(username, cfg.parents_group, cfg.yunohost_cli):
        raise HTTPException(status_code=403, detail="Parents group membership required")
