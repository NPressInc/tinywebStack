"""Family member listing and plain-language status labels."""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Literal

from tinywebstack_dashboard.auth import DashboardConfig, list_group_members
from tinywebstack_dashboard.yunohost_actions import synapse_user_status

Role = Literal["parent", "kid"]


@dataclass
class MemberRow:
    username: str
    role: Role
    mxid: str
    matrix_label: str


def matrix_status_label(status: dict[str, str]) -> str:
    st = status.get("status", "unknown")
    if st == "active":
        return "Ready — they can sign in to Element on their phone."
    if st == "deactivated":
        return "Chat account is turned off on the server."
    if st == "not_found":
        return "Not signed in yet — open Element once and it will connect."
    if st == "unknown":
        if status.get("detail") == "no_admin_token":
            return "Open Element once; detailed server status is not configured yet."
        if status.get("detail") == "helper_failed":
            return "Chat status temporarily unavailable."
    return "Chat status unknown."


def list_members(cfg: DashboardConfig) -> List[MemberRow]:
    try:
        parents = list_group_members(cfg.parents_group, cfg.yunohost_cli)
        kids = list_group_members(cfg.kids_group, cfg.yunohost_cli)
    except Exception:
        return []
    rows: List[MemberRow] = []
    for u in parents:
        st = synapse_user_status(u, cfg.server_name)
        rows.append(
            MemberRow(
                username=u,
                role="parent",
                mxid=f"@{u}:{cfg.server_name}",
                matrix_label=matrix_status_label(st),
            )
        )
    for u in kids:
        st = synapse_user_status(u, cfg.server_name)
        rows.append(
            MemberRow(
                username=u,
                role="kid",
                mxid=f"@{u}:{cfg.server_name}",
                matrix_label=matrix_status_label(st),
            )
        )
    return sorted(rows, key=lambda r: (0 if r.role == "parent" else 1, r.username))
