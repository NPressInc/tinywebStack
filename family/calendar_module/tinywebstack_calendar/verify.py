"""CalDAV checks for lab nodes (invite accept/decline round trip)."""

from __future__ import annotations

import argparse
import ssl
import sys
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional
from urllib.parse import urlparse

import caldav
from caldav.lib.error import AuthorizationError, NotFoundError
import vobject


def _ssl_context(cafile: str | None, insecure: bool) -> ssl.SSLContext | None:
    if insecure:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    if cafile:
        return ssl.create_default_context(cafile=cafile)
    return None


def dav_client(base_url: str, username: str, password: str, *, cafile: str | None, insecure: bool) -> caldav.DAVClient:
    ssl_verify = False if insecure else (cafile or True)
    return caldav.DAVClient(
        url=base_url,
        username=username,
        password=password,
        ssl_verify_ssl=ssl_verify,
    )


def find_calendar(client: caldav.DAVClient, calendar_id: str) -> caldav.objects.Calendar:
    principal = client.principal()
    for cal in principal.calendars():
        url = cal.url.path if hasattr(cal.url, "path") else str(cal.url)
        if calendar_id in url:
            return cal
    raise NotFoundError(f"calendar {calendar_id} not found for {client.username}")


def invite_roundtrip(
    *,
    caldav_root: str,
    owner_user: str,
    owner_password: str,
    attendee_user: str,
    attendee_password: str,
    calendar_id: str,
    attendee_email: str,
    cafile: str | None,
    insecure: bool,
) -> Dict[str, Any]:
    owner_client = dav_client(caldav_root, owner_user, owner_password, cafile=cafile, insecure=insecure)
    attendee_client = dav_client(caldav_root, attendee_user, attendee_password, cafile=cafile, insecure=insecure)

    cal = find_calendar(owner_client, calendar_id)
    start = datetime.now(timezone.utc).replace(microsecond=0) + timedelta(days=2)
    end = start + timedelta(hours=1)
    uid = f"tws-verify-{uuid.uuid4()}@tinywebstack"

    vevent = vobject.iCalendar()
    vevent.add("vevent")
    vevent.vevent.add("uid").value = uid
    vevent.vevent.add("dtstamp").value = start
    vevent.vevent.add("dtstart").value = start
    vevent.vevent.add("dtend").value = end
    vevent.vevent.add("summary").value = "tinywebStack calendar verify"
    attendee = vevent.vevent.add("attendee")
    attendee.value = f"mailto:{attendee_email}"
    attendee.params["PARTSTAT"] = ["NEEDS-ACTION"]
    attendee.params["RSVP"] = ["TRUE"]
    cal.save_event(vevent.serialize())

    inbox = attendee_client.principal().schedule_inbox()
    if inbox is None:
        raise RuntimeError("attendee has no scheduling inbox")

    found: Optional[caldav.objects.Event] = None
    for event in inbox.events():
        raw = event.data
        if uid in raw:
            found = event
            break
    if found is None:
        raise RuntimeError("invite not visible in attendee schedule inbox")

    cal_data = vobject.readOne(found.data)
    for att in cal_data.vevent.contents.get("attendee", []):
        att.params["PARTSTAT"] = ["ACCEPTED"]
    found.data = cal_data.serialize()
    found.save()

    return {"uid": uid, "status": "accepted", "calendar_id": calendar_id}


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
    login_p.add_argument("--password", required=True)

    invite_p = sub.add_parser("invite-roundtrip")
    invite_p.add_argument("--caldav-root", required=True)
    invite_p.add_argument("--calendar-id", default="tws-family")
    invite_p.add_argument("--owner-user", default="parent")
    invite_p.add_argument("--owner-password", required=True)
    invite_p.add_argument("--attendee-user", default="kid")
    invite_p.add_argument("--attendee-password", required=True)
    invite_p.add_argument("--attendee-email", required=True)

    for p in (login_p, invite_p):
        p.add_argument("--cafile", default="")
        p.add_argument("--insecure", action="store_true")

    args = parser.parse_args(argv)
    cafile = args.cafile or None

    if args.cmd == "login":
        verify_login(args.caldav_root, args.user, args.password, cafile=cafile, insecure=args.insecure)
        print("login ok")
        return 0

    result = invite_roundtrip(
        caldav_root=args.caldav_root,
        owner_user=args.owner_user,
        owner_password=args.owner_password,
        attendee_user=args.attendee_user,
        attendee_password=args.attendee_password,
        calendar_id=args.calendar_id,
        attendee_email=args.attendee_email,
        cafile=cafile,
        insecure=args.insecure,
    )
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
