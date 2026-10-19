import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/chat/chat_service.dart';
import 'package:tinyweb/src/shell/main_shell.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      enrollUrl: '/family/api/app/enroll',
    );

AppSession _session(String role) {
  final session = AppSession(store: InMemoryCredentialStore());
  session.enrollment = EnrollmentBundle(
    deviceId: 'd',
    username: 'u',
    role: role,
    mxid: '@u:family.example',
    serverName: 'family.example',
    dashboardToken: 'tok',
    apiBase: '/family/api',
    serverOrigin: 'https://family.example',
    discovery: _discovery(),
  );
  session.profile = AppMeProfile(
    username: 'u',
    role: role,
    mxid: '@u:family.example',
    quietHours: QuietHoursInfo(configured: false, active: false),
    eventsEnabled: true,
  );
  session.route = AppRoute.home;
  return session;
}

void main() {
  testWidgets('parent sees Locations tab', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MainShell(
          session: _session('parent'),
          chatService: UnconfiguredChatService(),
        ),
      ),
    );
    expect(find.text('Locations'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Calendar'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('kid does not see Locations tab', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MainShell(
          session: _session('kid'),
          chatService: UnconfiguredChatService(),
        ),
      ),
    );
    expect(find.text('Locations'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Calendar'),
      ),
      findsOneWidget,
    );
  });
}
