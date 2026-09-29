#!/usr/bin/env python3
"""Apply per-kid Mobilizon SSO + LDAP login gate from family-policy.json."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def _repo_root() -> Path:
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / "family" / "synapse_module" / "tinywebstack_family").is_dir():
            return parent
    raise RuntimeError(f"Cannot locate family/synapse_module from {here}")


sys.path.insert(0, str(_repo_root() / "family" / "synapse_module"))

from tinywebstack_family.mobilizon import (  # noqa: E402
    events_domain,
    kid_usernames_with_events,
    revoke_mobilizon_sessions_for_email,
)


def _run_json(cmd: list[str]) -> dict:
    proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return json.loads(proc.stdout)


def _ynh(*args: str, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["yunohost", "user", *args], capture_output=True, text=True, check=check)


def _group_members(group: str) -> set[str]:
    try:
        data = _run_json(["yunohost", "user", "group", "info", group, "--output-as", "json"])
    except subprocess.CalledProcessError:
        return set()
    members = data.get("members")
    if isinstance(members, dict):
        return {str(k) for k in members.keys()}
    if isinstance(members, list):
        return {str(m) for m in members}
    return set()


def _ensure_group(name: str) -> None:
    try:
        groups = _run_json(["yunohost", "user", "group", "list", "--output-as", "json"])
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"yunohost group list failed: {exc.stderr}") from exc
    if isinstance(groups, dict):
        known = set(groups.keys())
    elif isinstance(groups, list):
        known = set(groups)
    else:
        known = set()
    if name in known:
        return
    proc = _ynh("group", "create", name)
    if proc.returncode != 0:
        raise RuntimeError(f"failed to create group {name}: {proc.stderr}")


def _sync_group_membership(group: str, want: set[str]) -> None:
    have = _group_members(group)
    for user in sorted(want - have):
        _ynh("group", "add", group, user, check=True)
    for user in sorted(have - want):
        _ynh("group", "remove", group, user, check=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default="/etc/tinywebstack/family-policy.json")
    parser.add_argument("--permission", default="mobilizon.main")
    parser.add_argument("--kids-group", default="kids")
    parser.add_argument("--parents-group", default="parents")
    parser.add_argument("--federation-test-group", default="federation-test")
    parser.add_argument("--events-users-group", default=os.environ.get("TWS_EVENTS_USERS_GROUP", "events-users"))
    parser.add_argument("--admin-user", default=os.environ.get("YUNOHOST_ADMIN_USER", "twsowner"))
    parser.add_argument("--main-domain", default=os.environ.get("TWS_SERVER_NAME", ""))
    args = parser.parse_args()

    path = Path(args.policy)
    if not path.is_file():
        print(f"WARN: missing policy {path}", file=sys.stderr)
        return 0
    policy = json.loads(path.read_text(encoding="utf-8"))
    enabled_kids = kid_usernames_with_events(policy)
    kid_members = _group_members(args.kids_group)

    for username in kid_members:
        if username in enabled_kids:
            _ynh("permission", "add", args.permission, username)
        else:
            _ynh("permission", "remove", args.permission, username)

    ldap_allowed: set[str] = set(_group_members(args.parents_group))
    ldap_allowed.update(_group_members(args.federation_test_group))
    ldap_allowed.update(enabled_kids)
    ldap_allowed.add(args.admin_user)

    _ensure_group(args.events_users_group)
    _sync_group_membership(args.events_users_group, ldap_allowed)

    main_domain = args.main_domain.strip()
    if main_domain and os.environ.get("MOBILIZON_ADMIN_PASSWORD"):
        base = f"https://{events_domain(main_domain)}"
        admin_email = f"{args.admin_user}@{main_domain}"
        for username in kid_members:
            if username in enabled_kids:
                continue
            email = f"{username}@{main_domain}"
            try:
                revoke_mobilizon_sessions_for_email(
                    base,
                    admin_email,
                    os.environ["MOBILIZON_ADMIN_PASSWORD"],
                    email,
                )
            except Exception as exc:  # noqa: BLE001 — best effort after LDAP gate
                print(f"WARN: could not revoke Mobilizon sessions for {email}: {exc}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
