import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/calendar/caldav_client.dart';
import 'package:tinyweb/src/calendar/ics.dart';

void main() {
  const root = 'https://nc.example/nextcloud/remote.php/dav';

  test('listCalendars parses multistatus', () async {
    final client = CalDavClient.withClient(
      root: root,
      username: 'parent',
      password: 'secret',
      client: MockClient((request) async {
        expect(request.method, 'PROPFIND');
        expect(request.url.path, contains('/calendars/parent/'));
        return http.Response(
          '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:response>
    <D:href>/nextcloud/remote.php/dav/calendars/parent/tws-family/</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>Family</D:displayname>
        <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>''',
          207,
        );
      }),
    );
    final cals = await client.listCalendars();
    expect(cals, hasLength(1));
    expect(cals.first.calendarId, 'tws-family');
    expect(cals.first.displayName, 'Family');
  });

  test('queryEvents returns parsed ICS', () async {
    final ics = serializeIcsEvent(
      IcsEvent(
        uid: 'evt-1@x',
        dtStart: DateTime.utc(2026, 4, 1, 12),
        dtEnd: DateTime.utc(2026, 4, 1, 13),
        summary: 'Soccer',
      ),
    );
    final client = CalDavClient.withClient(
      root: root,
      username: 'kid',
      password: 'secret',
      client: MockClient((request) async {
        expect(request.method, 'REPORT');
        return http.Response(
          '''<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:response>
    <D:href>/nextcloud/remote.php/dav/calendars/kid/tws-family/evt-1.ics</D:href>
    <D:propstat>
      <D:prop>
        <D:getetag>"abc"</D:getetag>
        <C:calendar-data>$ics</C:calendar-data>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>''',
          207,
        );
      }),
    );
    final cal = CalDavCalendar(
      href: '$root/calendars/kid/tws-family/',
      displayName: 'Family',
      calendarId: 'tws-family',
    );
    final events = await client.queryEvents(
      cal,
      rangeStart: DateTime.utc(2026, 1, 1),
      rangeEnd: DateTime.utc(2026, 12, 31),
    );
    expect(events, hasLength(1));
    expect(events.first.event.summary, 'Soccer');
    expect(events.first.etag, '"abc"');
  });

  test('putEvent sends PUT with calendar body', () async {
    final client = CalDavClient.withClient(
      root: root,
      username: 'parent',
      password: 'secret',
      client: MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.headers['content-type'], contains('text/calendar'));
        expect(request.body, contains('BEGIN:VCALENDAR'));
        return http.Response('', 201, headers: {'etag': '"new"'});
      }),
    );
    final cal = CalDavCalendar(
      href: '$root/calendars/parent/tws-family/',
      displayName: 'Family',
      calendarId: 'tws-family',
    );
    final saved = await client.putEvent(
      calendar: cal,
      event: IcsEvent(
        uid: 'new@x',
        dtStart: DateTime.utc(2026, 5, 1, 9),
        dtEnd: DateTime.utc(2026, 5, 1, 10),
        summary: 'New',
      ),
    );
    expect(saved.event.summary, 'New');
    expect(saved.etag, '"new"');
  });
}
