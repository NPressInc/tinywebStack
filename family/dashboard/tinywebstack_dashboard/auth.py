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
    csrf_secret: str = ""
    yunohost_cli: str = "yunohost"
    owntracks_store_path: str = "/etc/tinywebstack/owntracks-kids.json"


def username_from_headers(headers: dict) -> Optional[str]:
    for key in ("Remote-User", "YNH_USER", "X-Remote-User"):
        val = headers.get(key) or headers.get(key.lower())
        if val:
            return str(val).strip().split("@")[0]
    return None


def list_group_members(group: str, yunohost_cli: str = "yunohost") -> List[str]:
    if os.environ.get("TWS_DASHBOARD_MOCK_GROUPS"):
        raw = os.environ.get("TWS_DASHBOARD_MOCK_GROUPS", "{}")
        mapping = json.loads(raw)
        return list(mapping.get(group, []))
    try:
        out = subprocess.check_output(
            [yunohost_cli, "user", "list", "--output-as", "json"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        users = json.loads(out)
    except (subprocess.CalledProcessError, json.JSONDecodeError, FileNotFoundError):
        return []
    members: List[str] = []
    for name, info in users.items():
        groups = info.get("group") or info.get("groups") or []
        if isinstance(groups, dict):
            groups = groups.keys()
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
