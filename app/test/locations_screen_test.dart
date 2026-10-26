import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/location/locations_screen.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      enrollUrl: '/family/api/app/enroll',
    );

AppSession _parentSession() {
  final session = AppSession(store: InMemoryCredentialStore());
  session.enrollment = EnrollmentBundle(
    deviceId: 'd',
    username: 'parent1',
    role: 'parent',
    mxid: '@parent1:family.example',
    serverName: 'family.example',
    dashboardToken: 'parent-token',
    apiBase: '/family/api',
    serverOrigin: 'https://family.example',
    discovery: _discovery(),
  );
  session.profile = AppMeProfile(
    username: 'parent1',
    role: 'parent',
    mxid: '@parent1:family.example',
    quietHours: QuietHoursInfo(configured: false, active: false),
    eventsEnabled: true,
  );
  session.route = AppRoute.home;
  return session;
}

FamilyApiClient _fakeApi() {
  final client = MockClient((request) async {
    if (request.url.path.endsWith('/map')) {
      return http.Response(
        '''
        {"available":false,"attribution":"© OpenStreetMap contributors, Protomaps","maxzoom":14,"flavor":"light","tiles_url":"https://family.example/family/tiles/basemap.pmtiles","glyphs_url":"https://family.example/family/tiles/fonts/{fontstack}/{range}.pbf","sprites_url":"https://family.example/family/tiles/sprites/v4/light","style_url":"https://family.example/family/tiles/style.json"}
        ''',
        200,
      );
    }
    if (request.url.path.endsWith('/locations')) {
      return http.Response(
        '''
        {"kids":[{"username":"kid1","display_name":"Kid One","lat":40.1,"lon":-105.2,"acc":8,"batt":90,"tst":1700000000,"age_seconds":120}]}
        ''',
        200,
      );
    }
    if (request.url.path.contains('/track')) {
      return http.Response(
        '''
        {"username":"kid1","display_name":"Kid One","hours":24,"points":[{"lat":40.1,"lon":-105.2,"tst":1700000000}]}
        ''',
        200,
      );
    }
    return http.Response('{}', 404);
  });
  return FamilyApiClient(client: client);
}

String _expectedTrackTimestamp(int tstSeconds) {
  final when =
      DateTime.fromMillisecondsSinceEpoch(tstSeconds * 1000).toLocal();
  final y = when.year;
  final m = when.month.toString().padLeft(2, '0');
  final d = when.day.toString().padLeft(2, '0');
  final h = when.hour.toString().padLeft(2, '0');
  final min = when.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $h:$min';
}

void main() {
  group('formatLocationAge', () {
    test('null is no data', () {
      expect(formatLocationAge(null), 'no data');
    });
    test('seconds', () {
      expect(formatLocationAge(45), '45s ago');
    });
    test('minutes', () {
      expect(formatLocationAge(120), '2m ago');
      expect(formatLocationAge(300), '5m ago');
    });
    test('hours', () {
      expect(formatLocationAge(7200), '2h ago');
    });
    test('days', () {
      expect(formatLocationAge(172800), '2d ago');
    });
  });

  testWidgets('locations screen lists kid snapshot', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LocationsScreen(
          session: _parentSession(),
          api: _fakeApi(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Kid One'), findsOneWidget);
    expect(find.textContaining('40.1'), findsWidgets);
  });

  testWidgets('locations screen shows friendly age, track time, and open in maps',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LocationsScreen(
          session: _parentSession(),
          api: _fakeApi(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Last seen: 2m ago'), findsOneWidget);
    expect(find.text(_expectedTrackTimestamp(1700000000)), findsOneWidget);
    expect(find.byKey(const Key('open-maps-kid1')), findsOneWidget);
    expect(find.byTooltip('Open in Maps'), findsOneWidget);
  });
}
