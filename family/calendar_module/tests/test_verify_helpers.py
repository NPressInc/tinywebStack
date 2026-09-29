from datetime import datetime, timedelta
from unittest import mock
from zoneinfo import ZoneInfo

import vobject

from tinywebstack_calendar.verify import _add_utc_vevent_times, _attendee_partstat, dav_client


def test_dav_client_uses_ssl_verify_cert() -> None:
    with mock.patch("tinywebstack_calendar.verify.caldav.DAVClient") as dc:
        dav_client("https://x/dav", "u", "p", cafile="/tmp/ca.pem", insecure=False)
    kwargs = dc.call_args.kwargs
    assert "ssl_verify_ssl" not in kwargs
    assert kwargs["ssl_verify_cert"] == "/tmp/ca.pem"


def test_vevent_utc_tzid_does_not_use_timezone_utc_object() -> None:
    utc = ZoneInfo("UTC")
    start = datetime(2026, 1, 15, 12, 0, tzinfo=utc)
    end = start + timedelta(hours=1)
    cal = vobject.iCalendar()
    cal.add("vevent")
    _add_utc_vevent_times(cal.vevent, start, end)
    serialized = cal.serialize()
    assert "TZID=UTC" in serialized or "TZID:UTC" in serialized
    vobject.readOne(serialized)


def test_attendee_partstat_parsed() -> None:
    raw = """BEGIN:VCALENDAR
BEGIN:VEVENT
UID:test@x
ATTENDEE;PARTSTAT=ACCEPTED:mailto:kid@family.test
END:VEVENT
END:VCALENDAR"""
    assert _attendee_partstat(raw, "kid@family.test") == "ACCEPTED"
