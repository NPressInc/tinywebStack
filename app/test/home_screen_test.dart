import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/home/home_screen.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      enrollUrl: '/family/api/app/enroll',
    );

AppSession _session({
  required String role,
  required bool quietActive,
  bool eventsEnabled = true,
}) {
  final session = AppSession(store: InMemoryCredentialStore());
  session.enrollment = EnrollmentBundle(
    deviceId: 'd',
    username: 'alice',
    role: role,
    mxid: '@alice:family.example',
    serverName: 'family.example',
    dashboardToken: 'tok',
    apiBase: '/family/api',
    serverOrigin: 'https://family.example',
    discovery: _discovery(),
  );
  session.profile = AppMeProfile(
    username: 'alice',
    role: role,
    mxid: '@alice:family.example',
    quietHours: QuietHoursInfo(
      configured: true,
      active: quietActive,
      windowEnd: '8:00',
    ),
    eventsEnabled: eventsEnabled,
  );
  session.route = AppRoute.home;
  return session;
}

void main() {
  testWidgets('shows quiet-hours banner when active', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(session: _session(role: 'kid', quietActive: true))),
    );
    expect(find.textContaining('Quiet hours'), findsOneWidget);
  });

  testWidgets('hides quiet-hours banner when inactive', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(session: _session(role: 'kid', quietActive: false))),
    );
    expect(find.textContaining('Quiet hours'), findsNothing);
  });

  testWidgets('kid hides family map and controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(session: _session(role: 'kid', quietActive: false))),
    );
    expect(find.text('Family map'), findsNothing);
    expect(find.text('Family controls'), findsNothing);
  });

  testWidgets('parent sees family controls tile', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(session: _session(role: 'parent', quietActive: false))),
    );
    expect(find.text('Family controls'), findsOneWidget);
    expect(find.text('Family map'), findsNothing);
  });

  testWidgets('kid with owntracks sees location sharing card', (tester) async {
    final session = _session(role: 'kid', quietActive: false);
    session.enrollment = EnrollmentBundle(
      deviceId: 'd',
      username: 'alice',
      role: 'kid',
      mxid: '@alice:family.example',
      serverName: 'family.example',
      dashboardToken: 'tok',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: _discovery(),
      rawJson: {
        'owntracks': {
          'url': 'https://ot.example/pub',
          'username': 'alice',
          'device': 'phone',
          'password': 'x',
          'tid': 'a1',
          'publish': true,
          'mode': 'http',
        },
      },
    );
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(session: session)),
    );
    expect(find.text('Location sharing'), findsOneWidget);
  });

  testWidgets('events tile hidden when disabled', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          session: _session(role: 'parent', quietActive: false, eventsEnabled: false),
        ),
      ),
    );
    expect(find.text('Events'), findsNothing);
  });
}
