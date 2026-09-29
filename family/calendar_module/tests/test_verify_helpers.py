from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

import vobject

from tinywebstack_calendar.verify import (
    _add_utc_vevent_times,
    _attendee_partstat,
    _caldav_absolute_url,
    _delete_events_in_collection,
    _purge_trashbin_objects,
    _purge_uid_residue,
    _trashbin_object_hrefs_matching_uid,
    dav_client,
)

FIXTURES = Path(__file__).resolve().parent / "fixtures"


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


def test_trashbin_report_parses_recorded_nextcloud_response() -> None:
    xml = (FIXTURES / "trashbin_report.xml").read_text()
    hrefs = _trashbin_object_hrefs_matching_uid(xml, "tws-verify-deadbeef@tinywebstack")
    assert len(hrefs) == 1
    assert "tws-verify-deadbeef@tinywebstack-deleted.ics" in hrefs[0]


def test_purge_trashbin_objects_report_then_delete() -> None:
    uid = "tws-verify-deadbeef@tinywebstack"
    report_xml = (FIXTURES / "trashbin_report.xml").read_text()
    caldav_root = "https://nextcloud.test/nextcloud/remote.php/dav"
    deleted: list[str] = []

    def fake_open(url: str, *, method: str, **_kwargs: object) -> tuple[int, str, dict[str, str]]:
        if method == "REPORT":
            assert url.endswith("/calendars/parent/trashbin/objects/")
            return 207, report_xml, {}
        if method == "DELETE":
            deleted.append(url)
            return 204, "", {}
        raise AssertionError(f"unexpected {method} {url}")

    with mock.patch("tinywebstack_calendar.verify._open_caldav", side_effect=fake_open):
        _purge_trashbin_objects(caldav_root, "parent", "secret", uid, cafile=None, insecure=True)

    assert len(deleted) == 1
    assert deleted[0] == _caldav_absolute_url(
        caldav_root,
        "/nextcloud/remote.php/dav/calendars/parent/trashbin/objects/"
        "abc-tws-verify-deadbeef@tinywebstack-deleted.ics",
    )


def test_purge_uid_residue_calls_trashbin_report() -> None:
    uid = "tws-verify-test@tinywebstack"
    live_event = mock.Mock(data=f"UID:{uid}")
    inbox_event = mock.Mock(data=f"UID:{uid}")

    live_cal = mock.Mock()
    live_cal.events.side_effect = [[live_event], []]

    principal = mock.Mock()
    principal.calendars.return_value = [live_cal]
    inbox = mock.Mock()
    inbox.events.side_effect = [[inbox_event], []]
    principal.schedule_inbox.return_value = inbox
    principal.schedule_outbox.return_value = None

    client = mock.Mock()
    client.username = "parent"
    client.principal.return_value = principal

    with mock.patch("tinywebstack_calendar.verify._purge_trashbin_objects") as trash_purge:
        _purge_uid_residue(
            client,
            uid,
            caldav_root="https://x/dav",
            password="p",
            cafile=None,
            insecure=False,
        )

    trash_purge.assert_called_once_with(
        "https://x/dav",
        "parent",
        "p",
        uid,
        cafile=None,
        insecure=False,
    )
    live_event.delete.assert_called_once()
    inbox_event.delete.assert_called()


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
