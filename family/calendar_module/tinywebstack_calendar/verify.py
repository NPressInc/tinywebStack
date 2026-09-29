"""CalDAV checks for lab nodes (invite accept/decline round trip)."""

from __future__ import annotations

import argparse
import os
import ssl
import sys
import time
import uuid
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional
from zoneinfo import ZoneInfo

import caldav
from caldav.lib.error import AuthorizationError, NotFoundError
import vobject


def _ssl_verify(cafile: str | None, insecure: bool) -> bool | str:
    if insecure:
        return False
    return cafile if cafile else True


def dav_client(base_url: str, username: str, password: str, *, cafile: str | None, insecure: bool) -> caldav.DAVClient:
    return caldav.DAVClient(
        url=base_url,
        username=username,
        password=password,
        ssl_verify_cert=_ssl_verify(cafile, insecure),
    )


def find_calendar(client: caldav.DAVClient, calendar_id: str) -> caldav.objects.Calendar:
    principal = client.principal()
    for cal in principal.calendars():
        url = cal.url.path if hasattr(cal.url, "path") else str(cal.url)
        if calendar_id in url:
            return cal
    raise NotFoundError(f"calendar {calendar_id} not found for {client.username}")


def _password_from_env(env_key: str, cli_value: str | None) -> str:
    if cli_value:
        return cli_value
    env = os.environ.get(env_key, "")
    if env:
        return env
    raise SystemExit(f"missing password: set {env_key} or pass the matching CLI flag")


def _add_utc_vevent_times(vevent: vobject.base.Component, start: datetime, end: datetime) -> None:
    mapping = {
        "dtstamp": start.replace(tzinfo=None),
        "dtstart": start.replace(tzinfo=None),
        "dtend": end.replace(tzinfo=None),
    }
    for comp, value in mapping.items():
        node = vevent.add(comp)
        node.value = value
        node.params["TZID"] = ["UTC"]


def _find_event_by_uid(client: caldav.DAVClient, uid: str, *, wait_seconds: float = 20.0) -> Optional[caldav.objects.Event]:
    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        principal = client.principal()
        for cal in principal.calendars():
            for event in cal.events():
                if uid in (event.data or ""):
                    return event
        time.sleep(1.0)
    return None


def _attendee_partstat(event_data: str, attendee_email: str) -> Optional[str]:
    cal = vobject.readOne(event_data)
    for att in cal.vevent.contents.get("attendee", []):
        mail = att.value.replace("mailto:", "").lower()
        if mail == attendee_email.lower():
            partstat = att.params.get("PARTSTAT", ["UNKNOWN"])
            return partstat[0] if partstat else "UNKNOWN"
    return None


def invite_roundtrip(
    *,
    caldav_root: str,
    owner_user: str,
    owner_password: str,
    attendee_user: str,
    attendee_password: str,
    calendar_id: str,
    attendee_email: str,
    organizer_email: str,
    cafile: str | None,
    insecure: bool,
) -> Dict[str, Any]:
    owner_client = dav_client(caldav_root, owner_user, owner_password, cafile=cafile, insecure=insecure)
    attendee_client = dav_client(caldav_root, attendee_user, attendee_password, cafile=cafile, insecure=insecure)

    cal = find_calendar(owner_client, calendar_id)
    utc = ZoneInfo("UTC")
    start = datetime.now(tz=utc).replace(microsecond=0) + timedelta(days=2)
    end = start + timedelta(hours=1)
    uid = f"tws-verify-{uuid.uuid4()}@tinywebstack"

    vevent = vobject.iCalendar()
    vevent.add("vevent")
    vevent.vevent.add("uid").value = uid
    _add_utc_vevent_times(vevent.vevent, start, end)
    vevent.vevent.add("summary").value = "tinywebStack calendar verify"
    org = vevent.vevent.add("organizer")
    org.value = f"mailto:{organizer_email}"
    org.params["CN"] = [owner_user]
    attendee = vevent.vevent.add("attendee")
    attendee.value = f"mailto:{attendee_email}"
    attendee.params["PARTSTAT"] = ["NEEDS-ACTION"]
    attendee.params["RSVP"] = ["TRUE"]
    cal.save_event(vevent.serialize())

    found = _find_event_by_uid(attendee_client, uid)
    if found is None:
        raise RuntimeError("invite not visible on attendee calendars")

    def _set_partstat(partstat: str) -> None:
        nonlocal found
        assert found is not None
        cal_data = vobject.readOne(found.data)
        for att in cal_data.vevent.contents.get("attendee", []):
            att.params["PARTSTAT"] = [partstat]
        found.data = cal_data.serialize()
        found.save()

    _set_partstat("ACCEPTED")
    owner_event = _find_event_by_uid(owner_client, uid, wait_seconds=25.0)
    if owner_event is None:
        raise RuntimeError("organizer copy missing after accept")
    if _attendee_partstat(owner_event.data, attendee_email) != "ACCEPTED":
        raise RuntimeError("organizer did not see ACCEPTED after attendee accept")

    found = _find_event_by_uid(attendee_client, uid, wait_seconds=10.0) or found
    _set_partstat("DECLINED")
    owner_event = _find_event_by_uid(owner_client, uid, wait_seconds=25.0)
    if owner_event is None:
        raise RuntimeError("organizer copy missing after decline")
    if _attendee_partstat(owner_event.data, attendee_email) != "DECLINED":
        raise RuntimeError("organizer did not see DECLINED after attendee decline")

    return {"uid": uid, "status": "accept_and_decline", "calendar_id": calendar_id}


def verify_login(caldav_root: str, username: str, password: str, *, cafile: str | None, insecure: bool) -> None:
    client = dav_client(caldav_root, username, password, cafile=cafile, insecure=insecure)
    try:
        client.principal()
    except AuthorizationError as exc:
        raise RuntimeError(f"CalDAV login failed for {username}") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify Nextcloud CalDAV on a family node")
    sub = parser.add_subparsers(dest="cmd", required=True)

    login_p = sub.add_parser("login")
    login_p.add_argument("--caldav-root", required=True)
    login_p.add_argument("--user", required=True)
    login_p.add_argument("--password", default="")

    invite_p = sub.add_parser("invite-roundtrip")
    invite_p.add_argument("--caldav-root", required=True)
    invite_p.add_argument("--calendar-id", default="tws-family")
    invite_p.add_argument("--owner-user", default="parent")
    invite_p.add_argument("--owner-password", default="")
    invite_p.add_argument("--attendee-user", default="kid")
    invite_p.add_argument("--attendee-password", default="")
    invite_p.add_argument("--attendee-email", required=True)
    invite_p.add_argument("--organizer-email", default="")

    for p in (login_p, invite_p):
        p.add_argument("--cafile", default="")
        p.add_argument("--insecure", action="store_true")

    args = parser.parse_args(argv)
    cafile = args.cafile or None

    if args.cmd == "login":
        password = _password_from_env("TWS_CALENDAR_VERIFY_PASSWORD", args.password or None)
        verify_login(args.caldav_root, args.user, password, cafile=cafile, insecure=args.insecure)
        print("login ok")
        return 0

    owner_password = _password_from_env("TWS_CALENDAR_VERIFY_PARENT_PASSWORD", args.owner_password or None)
    attendee_password = _password_from_env("TWS_CALENDAR_VERIFY_KID_PASSWORD", args.attendee_password or None)
    organizer_email = args.organizer_email or os.environ.get(
        "TWS_CALENDAR_VERIFY_ORGANIZER_EMAIL",
        f"{args.owner_user}@example.com",
    )

    result = invite_roundtrip(
        caldav_root=args.caldav_root,
        owner_user=args.owner_user,
        owner_password=owner_password,
        attendee_user=args.attendee_user,
        attendee_password=attendee_password,
        calendar_id=args.calendar_id,
        attendee_email=args.attendee_email,
        organizer_email=organizer_email,
        cafile=cafile,
        insecure=args.insecure,
    )
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
