"""Idempotent shared calendar provisioning on a YunoHost Nextcloud node."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List

from tinywebstack_calendar.naming import (
    CALENDAR_DISPLAY,
    CALENDAR_IDS,
    caldav_root,
    family_group_name,
    principal_calendar_url,
)
from tinywebstack_calendar.sharing import group_principal, share_calendar_with_principal

STATE_PATH = Path("/etc/tinywebstack/calendar-state.json")

# Disable noisy Nextcloud apps for v1 (calendar-only UX). Keep core DAV + sharing apps enabled.
DISABLED_NC_APPS = (
    "files",
    "photos",
    "spreed",
    "dashboard",
    "firstrunwizard",
    "weather_status",
    "recommendations",
    "survey_client",
    "text",
)

KEEP_NC_APPS = frozenset(
    {
        "calendar",
        "dav",
        "user_ldap",
        "lookup_server_connector",
        "oauth2",
        "provisioning_api",
        "settings",
        "systemtags",
        "updatenotification",
        "user_status",
        "viewer",
    }
)


def run_occ(occ_cmd: List[str], *, occ_path: str, run_as: str) -> str:
    full = ["sudo", "-u", run_as, "php", occ_path, *occ_cmd]
    proc = subprocess.run(full, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"occ {' '.join(occ_cmd)} failed: {proc.stderr or proc.stdout}")
    return proc.stdout


def list_calendars(occ_path: str, run_as: str, username: str) -> List[str]:
    out = run_occ(["dav:list-calendars", username], occ_path=occ_path, run_as=run_as)
    ids: List[str] = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("User "):
            continue
        # " - tws-family (Family)"
        if line.startswith("- "):
            slug = line[2:].split(" ", 1)[0]
            ids.append(slug)
    return ids


def ensure_calendar(
    occ_path: str,
    run_as: str,
    owner: str,
    calendar_id: str,
    existing: List[str],
) -> None:
    if calendar_id in existing:
        return
    run_occ(["dav:create-calendar", owner, calendar_id], occ_path=occ_path, run_as=run_as)


def ensure_personal_calendar(occ_path: str, run_as: str, username: str) -> None:
    existing = list_calendars(occ_path, run_as, username)
    personal_id = f"personal-{username}"
    if personal_id in existing or "personal" in existing:
        return
    run_occ(["dav:create-calendar", username, personal_id], occ_path=occ_path, run_as=run_as)


def _enabled_apps(list_output: str) -> set[str]:
    enabled: set[str] = set()
    section = ""
    for line in list_output.splitlines():
        line = line.strip()
        if line.endswith(":"):
            section = line[:-1].lower()
            continue
        if section == "enabled" and line:
            enabled.add(line.split()[0])
    return enabled


def apply_nextcloud_hardening(occ_path: str, run_as: str) -> None:
    listed = run_occ(["app:list"], occ_path=occ_path, run_as=run_as)
    enabled = _enabled_apps(listed)
    for app_id in DISABLED_NC_APPS:
        if app_id in enabled and app_id not in KEEP_NC_APPS:
            try:
                run_occ(["app:disable", app_id], occ_path=occ_path, run_as=run_as)
            except RuntimeError:
                pass
    run_occ(["app:enable", "calendar"], occ_path=occ_path, run_as=run_as)
    run_occ(
        ["config:system:set", "defaultapp", "--value", "calendar", "--type=string"],
        occ_path=occ_path,
        run_as=run_as,
    )
    run_occ(
        ["config:app:set", "dav", "create_example_event", "--value", "no"],
        occ_path=occ_path,
        run_as=run_as,
    )


def share_household_calendars(
    *,
    main_domain: str,
    owner: str,
    owner_password: str,
    parents_group: str,
    kids_group: str,
    family_group: str,
    nextcloud_path: str,
    cafile: str | None,
) -> None:
    shares = [
        (CALENDAR_IDS["family"], family_group, "read-write"),
        (CALENDAR_IDS["parents"], parents_group, "read-write"),
        (CALENDAR_IDS["kids"], kids_group, "read-write"),
    ]
    for cal_id, group, access in shares:
        url = principal_calendar_url(main_domain, owner, cal_id, nextcloud_path)
        share_calendar_with_principal(
            url,
            owner,
            owner_password,
            group_principal(group),
            access=access,  # type: ignore[arg-type]
            cafile=cafile,
        )
    # Parents can always manage the kids calendar.
    parents_on_kids = principal_calendar_url(main_domain, owner, CALENDAR_IDS["kids"], nextcloud_path)
    share_calendar_with_principal(
        parents_on_kids,
        owner,
        owner_password,
        group_principal(parents_group),
        access="read-write",
        cafile=cafile,
    )


def build_state(
    *,
    main_domain: str,
    node_name: str,
    owner: str,
    nextcloud_path: str,
    family_group: str,
) -> Dict[str, Any]:
    return {
        "main_domain": main_domain,
        "node_name": node_name,
        "owner": owner,
        "nextcloud_path": nextcloud_path,
        "family_group": family_group,
        "caldav_root": caldav_root(main_domain, nextcloud_path),
        "calendars": {
            key: {
                "id": CALENDAR_IDS[key],
                "display": CALENDAR_DISPLAY[key],
                "url": principal_calendar_url(main_domain, owner, CALENDAR_IDS[key], nextcloud_path),
            }
            for key in CALENDAR_IDS
        },
    }


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Provision tinywebStack shared calendars on Nextcloud")
    parser.add_argument("main_domain")
    parser.add_argument("node_name")
    parser.add_argument("--occ-path", required=True)
    parser.add_argument("--occ-user", required=True)
    parser.add_argument("--owner", default="parent")
    parser.add_argument("--owner-password", required=True)
    parser.add_argument("--parents-group", default="parents")
    parser.add_argument("--kids-group", default="kids")
    parser.add_argument("--nextcloud-path", default="/nextcloud")
    parser.add_argument("--users", default="parent,kid", help="Comma-separated LDAP users to ensure personal calendars")
    parser.add_argument("--cafile", default="")
    parser.add_argument("--state-path", default=str(STATE_PATH))
    args = parser.parse_args(argv)

    family_group = family_group_name(args.main_domain, args.node_name)
    cafile = args.cafile or None

    apply_nextcloud_hardening(args.occ_path, args.occ_user)

    existing = list_calendars(args.occ_path, args.occ_user, args.owner)
    for key in CALENDAR_IDS:
        ensure_calendar(args.occ_path, args.occ_user, args.owner, CALENDAR_IDS[key], existing)
        existing = list_calendars(args.occ_path, args.occ_user, args.owner)

    for user in [u.strip() for u in args.users.split(",") if u.strip()]:
        ensure_personal_calendar(args.occ_path, args.occ_user, user)

    share_household_calendars(
        main_domain=args.main_domain,
        owner=args.owner,
        owner_password=args.owner_password,
        parents_group=args.parents_group,
        kids_group=args.kids_group,
        family_group=family_group,
        nextcloud_path=args.nextcloud_path,
        cafile=cafile,
    )

    state = build_state(
        main_domain=args.main_domain,
        node_name=args.node_name,
        owner=args.owner,
        nextcloud_path=args.nextcloud_path,
        family_group=family_group,
    )
    state_path = Path(args.state_path)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "ok", "family_group": family_group, "state_path": str(state_path)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
