import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/family/kid_controls_screen.dart';
import 'package:tinyweb/src/family/kid_detail_screen.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      dashboardBase: '/family',
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
  return FamilyApiClient(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/invites')) {
        return http.Response(jsonEncode([]), 200);
      }
      if (request.url.path.endsWith('/members') && request.method == 'GET') {
        return http.Response(
          jsonEncode([
            {
              'username': 'kid1',
              'role': 'kid',
              'mxid': '@kid1:family.example',
              'display_name': 'Kid One',
              'device_count': 0,
            },
          ]),
          200,
        );
      }
      if (request.url.path.endsWith('/permissions/kid1')) {
        if (request.method == 'PUT') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'username': 'kid1',
              'mxid': '@kid1:family.example',
              'role': 'kid',
              'events_enabled': body['events_enabled'] ?? true,
              'allowlist_mxids': body['allowlist_mxids'] ?? [],
              'allowlist_domains': body['allowlist_domains'] ?? [],
              'quiet_hours': body['quiet_hours'],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'username': 'kid1',
            'mxid': '@kid1:family.example',
            'role': 'kid',
            'events_enabled': true,
            'allowlist_mxids': [],
            'allowlist_domains': [],
            'quiet_hours': null,
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/federation')) {
        return http.Response(
          jsonEncode({'trusted_domains': [], 'peer_nodes': []}),
          200,
        );
      }
      return http.Response('{}', 404);
    }),
  );
}

void main() {
  testWidgets('kid controls lists children', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: KidControlsScreen(
          session: _parentSession(),
          api: _fakeApi(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Kid One'), findsOneWidget);
  });

  testWidgets('kid detail toggles events with optimistic UI', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: KidDetailScreen(
          session: _parentSession(),
          kid: FamilyMember(
            username: 'kid1',
            mxid: '@kid1:family.example',
            role: 'kid',
            displayName: 'Kid One',
          ),
          api: _fakeApi(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Allow Events app'), findsOneWidget);
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsWidgets);
  });
}
