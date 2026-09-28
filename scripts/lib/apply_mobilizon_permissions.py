#!/usr/bin/env python3
"""Apply per-kid Mobilizon SSO permissions from family-policy.json (events_enabled)."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "family" / "synapse_module"))

from tinywebstack_family.mobilizon import kid_usernames_with_events  # noqa: E402


def _ynh(*args: str) -> None:
    subprocess.run(["yunohost", "user", "permission", *args], check=False)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default="/etc/tinywebstack/family-policy.json")
    parser.add_argument("--permission", default="mobilizon.main")
    parser.add_argument("--kids-group", default="kids")
    args = parser.parse_args()

    path = Path(args.policy)
    if not path.is_file():
        print(f"WARN: missing policy {path}", file=sys.stderr)
        return 0
    policy = json.loads(path.read_text(encoding="utf-8"))
    enabled = kid_usernames_with_events(policy)

    # Group grant is handled by family-groups.sh; refine per-kid toggles here.
    listed = subprocess.run(
        ["yunohost", "user", "list", "--output-as-json"],
        capture_output=True,
        text=True,
        check=True,
    )
    users = json.loads(listed.stdout).get("users", json.loads(listed.stdout))
    kid_members = []
    for username, meta in users.items():
        groups = meta.get("groups") or []
        if args.kids_group in groups:
            kid_members.append(username)

    for username in kid_members:
        if username in enabled:
            _ynh("add", args.permission, username)
        else:
            _ynh("remove", args.permission, username)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
