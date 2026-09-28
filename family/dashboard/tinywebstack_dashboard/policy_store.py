"""Dashboard read/write of /etc/tinywebstack/family-policy.json."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Set

from tinywebstack_family.policy import empty_policy, write_policy_atomic


def load_policy(path: Path) -> Dict[str, Any]:
    if not path.is_file():
        return empty_policy("")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("policy must be a JSON object")
    return data


def sync_kids_from_usernames(
    policy: Dict[str, Any],
    kid_usernames: List[str],
    server_name: str,
) -> Dict[str, Any]:
    """Ensure each kid LDAP user has a policy entry (@user:server)."""
    kids = dict(policy.get("kids") or {})
    for user in kid_usernames:
        mxid = f"@{user}:{server_name}"
        kids.setdefault(
            mxid,
            {"allowlist_mxids": [], "allowlist_domains": [], "events_enabled": True},
        )
    # Drop entries for removed kids.
    keep = {f"@{u}:{server_name}" for u in kid_usernames}
    kids = {k: v for k, v in kids.items() if k in keep}
    policy["kids"] = kids
    policy["server_name"] = server_name
    return policy


def set_parent_mxids(policy: Dict[str, Any], parent_usernames: List[str], server_name: str) -> None:
    policy["parent_mxids"] = [f"@{u}:{server_name}" for u in parent_usernames]


def save_policy(path: Path, data: Dict[str, Any]) -> None:
    write_policy_atomic(path, data)
