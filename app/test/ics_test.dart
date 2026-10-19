import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/calendar/ics.dart';

void main() {
  test('parse and serialize VEVENT round trip', () {
    const raw = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:test-uid@example.com
DTSTAMP:20260115T120000Z
DTSTART;VALUE=DATE:20260120
DTEND;VALUE=DATE:20260121
SUMMARY:Family dinner
LOCATION:Home
DESCRIPTION:Bring dessert
ORGANIZER;CN=parent:mailto:parent@family.example
ATTENDEE;CN=kid;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:kid@family.example
END:VEVENT
END:VCALENDAR''';

    final events = parseIcsCalendar(raw);
    expect(events, hasLength(1));
    final ev = events.first;
    expect(ev.uid, 'test-uid@example.com');
    expect(ev.allDay, isTrue);
    expect(ev.summary, 'Family dinner');
    expect(ev.attendees, hasLength(1));
    expect(ev.attendees.first.partStat, 'NEEDS-ACTION');

    final out = serializeIcsEvent(ev);
    final again = parseIcsCalendar(out);
    expect(again.first.uid, ev.uid);
    expect(again.first.summary, ev.summary);
    expect(again.first.attendees.first.email, contains('kid@family.example'));
  });

  test('parse timed event with UTC', () {
    const raw = '''BEGIN:VCALENDAR
BEGIN:VEVENT
UID:timed@x
DTSTART:20260201T150000Z
DTEND:20260201T160000Z
SUMMARY:Call
END:VEVENT
END:VCALENDAR''';
    final ev = parseIcsCalendar(raw).first;
    expect(ev.allDay, isFalse);
    expect(ev.dtStart?.hour, 15);
    expect(ev.dtEnd?.hour, 16);
  });

  test('update attendee PARTSTAT in serialized output', () {
    final ev = IcsEvent(
      uid: 'u@x',
      dtStart: DateTime.utc(2026, 3, 1, 10),
      dtEnd: DateTime.utc(2026, 3, 1, 11),
      summary: 'Meet',
      attendees: [
        IcsAttendee(email: 'kid@family.test', partStat: 'ACCEPTED', rsvp: true),
      ],
    );
    final ics = serializeIcsEvent(ev);
    expect(ics, contains('PARTSTAT=ACCEPTED'));
  });
}
