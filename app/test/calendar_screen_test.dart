import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/calendar/caldav_client.dart';
import 'package:tinyweb/src/calendar/calendar_screen.dart';
import 'package:tinyweb/src/calendar/calendar_service.dart';
import 'package:tinyweb/src/calendar/ics.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

class _FakeCalendarService extends CalendarService {
  _FakeCalendarService(EnrollmentBundle bundle) : super(bundle: bundle);

  @override
  Future<List<CalendarEventView>> loadUpcoming({
    Duration horizon = const Duration(days: 90),
    int pastDays = 7,
  }) async {
    final cal = CalDavCalendar(
      href: 'https://x/calendars/parent/tws-family/',
      displayName: 'Family',
      calendarId: 'tws-family',
    );
    final ev = IcsEvent(
      uid: 'u@x',
      dtStart: DateTime.utc(2026, 6, 1, 15),
      dtEnd: DateTime.utc(2026, 6, 1, 16),
      summary: 'Picnic',
    );
    return [
      CalendarEventView(
        object: CalDavEventObject(
          href: 'https://x/e.ics',
          etag: '"1"',
          ics: '',
          event: ev,
          calendarHref: cal.href,
        ),
        calendar: cal,
        isOrganizer: true,
        myPartStat: null,
        needsMyResponse: false,
      ),
    ];
  }
}

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      enrollUrl: '/family/api/app/enroll',
      serverName: 'family.example',
    );

AppSession _session() {
  final session = AppSession(store: InMemoryCredentialStore());
  session.enrollment = EnrollmentBundle(
    deviceId: 'd',
    username: 'parent',
    role: 'parent',
    mxid: '@parent:family.example',
    serverName: 'family.example',
    dashboardToken: 'tok',
    apiBase: '/family/api',
    serverOrigin: 'https://family.example',
    discovery: _discovery(),
    rawJson: {
      'caldav': {
        'root': 'https://nc.example/dav',
        'username': 'parent',
        'password': 'pw',
      },
    },
  );
  session.profile = AppMeProfile(
    username: 'parent',
    role: 'parent',
    mxid: '@parent:family.example',
    quietHours: QuietHoursInfo(configured: false, active: false),
    eventsEnabled: true,
  );
  return session;
}

void main() {
  testWidgets('calendar screen lists events', (tester) async {
    final session = _session();
    await tester.pumpWidget(
      MaterialApp(
        home: CalendarScreen(
          session: session,
          service: _FakeCalendarService(session.enrollment!),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Picnic'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
  });
}
