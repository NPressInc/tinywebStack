from datetime import datetime, timedelta
from unittest import mock
from zoneinfo import ZoneInfo

import vobject

from tinywebstack_calendar.verify import (
    _add_utc_vevent_times,
    _attendee_partstat,
    _delete_events_in_collection,
    _purge_uid_residue,
    dav_client,
)


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


def test_purge_uid_residue_deletes_trashbin_and_inbox() -> None:
    uid = "tws-verify-test@tinywebstack"
    live_event = mock.Mock(data=f"UID:{uid}")
    trash_event = mock.Mock(data=f"UID:{uid}")
    inbox_event = mock.Mock(data=f"UID:{uid}")

    live_cal = mock.Mock()
    live_cal.url = mock.Mock(path="/calendars/parent/tws-family/")
    live_cal.events.side_effect = [[live_event], [], []]

    trash_cal = mock.Mock()
    trash_cal.url = mock.Mock(path="/calendars/parent/trashbin/")
    trash_cal.events.side_effect = [[], [trash_event], []]

    principal = mock.Mock()
    principal.calendars.return_value = [live_cal, trash_cal]
    inbox = mock.Mock()
    inbox.events.side_effect = [[inbox_event], []]
    principal.schedule_inbox.return_value = inbox
    principal.schedule_outbox.return_value = None

    client = mock.Mock()
    client.principal.return_value = principal

    _purge_uid_residue(client, uid)

    live_event.delete.assert_called_once()
    trash_event.delete.assert_called_once()
    inbox_event.delete.assert_called_once()


def test_delete_events_in_collection_ignores_other_uids() -> None:
    keep = mock.Mock(data="UID:keep-me@x")
    drop = mock.Mock(data="UID:drop-me@x")
    col = mock.Mock()
    col.events.return_value = [keep, drop]
    _delete_events_in_collection(col, "drop-me@x")
    keep.delete.assert_not_called()
    drop.delete.assert_called_once()


def test_attendee_partstat_parsed() -> None:
    raw = """BEGIN:VCALENDAR
BEGIN:VEVENT
UID:test@x
ATTENDEE;PARTSTAT=ACCEPTED:mailto:kid@family.test
END:VEVENT
END:VCALENDAR"""
    assert _attendee_partstat(raw, "kid@family.test") == "ACCEPTED"
