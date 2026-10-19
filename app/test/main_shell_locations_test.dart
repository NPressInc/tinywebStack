import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/family_api.dart';
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

FamilyApiClient _locationsApi() {
  final client = MockClient((request) async {
    if (request.url.path.endsWith('/map')) {
      return http.Response(
        '{"available":false,"attribution":"x","maxzoom":14,"flavor":"light","tiles_url":"https://family.example/family/tiles/basemap.pmtiles","glyphs_url":"https://family.example/family/tiles/fonts/x","sprites_url":"https://family.example/family/tiles/sprites/v4/light","style_url":"https://family.example/family/tiles/style.json"}',
        200,
      );
    }
    if (request.url.path.endsWith('/locations')) {
      return http.Response('{"kids":[]}', 200);
    }
    return http.Response('{}', 404);
  });
  return FamilyApiClient(client: client);
}

void main() {
  testWidgets('parent sees Events and Locations tabs', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MainShell(
          session: _session('parent'),
          chatService: UnconfiguredChatService(),
          locationsApi: _locationsApi(),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Events'),
      ),
      findsOneWidget,
    );
    expect(find.text('Locations'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Calendar'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('kid with events disabled does not see Events tab', (tester) async {
    final session = _session('kid');
    session.profile = AppMeProfile(
      username: 'u',
      role: 'kid',
      mxid: '@u:family.example',
      quietHours: QuietHoursInfo(configured: false, active: false),
      eventsEnabled: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MainShell(
          session: session,
          chatService: UnconfiguredChatService(),
          locationsApi: _locationsApi(),
        ),
      ),
    );
    expect(find.text('Events'), findsNothing);
  });

  testWidgets('kid does not see Locations tab', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MainShell(
          session: _session('kid'),
          chatService: UnconfiguredChatService(),
          locationsApi: _locationsApi(),
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
