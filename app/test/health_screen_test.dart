import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/health/health_screen.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      enrollUrl: '/family/api/app/enroll',
    );

EnrollmentBundle _bundle(String role) => EnrollmentBundle(
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

AppMeProfile _profile(String role) => AppMeProfile(
      username: 'alice',
      role: role,
      mxid: '@alice:family.example',
      quietHours: QuietHoursInfo(configured: false, active: false, windowEnd: ''),
      eventsEnabled: true,
    );

void main() {
  test('fetchHealth reads parent status and hides secrets', () async {
    final api = FamilyApiClient(
      client: MockClient((request) async {
        expect(request.url.path, '/family/api/health');
        expect(request.headers['Authorization'], 'Bearer tok');
        return http.Response(
          jsonEncode({
            'overall': 'warning',
            'checked_at': '2026-11-10T12:00:00Z',
            'cached': false,
            'checks': [
              {
                'id': 'synapse',
                'title': 'Chat',
                'status': 'ok',
                'summary': 'Chat is working.',
                'hint': '',
                'checked_at': '2026-11-10T12:00:00Z',
              },
              {
                'id': 'push',
                'title': 'Phone notifications',
                'status': 'problem',
                'summary': 'See /etc/tinywebstack/synapse-admin-token and tws_supersecretvalue',
                'hint': 'Bearer tws_supersecretvalue',
                'checked_at': '2026-11-10T12:00:00Z',
              },
            ],
          }),
          200,
        );
      }),
    );
    final report = await api.fetchHealth(_bundle('parent'));
    expect(report.overall, 'warning');
    expect(report.checks.first.statusLabel, 'OK');
    expect(report.checks.last.summary, 'Details are hidden.');
    expect(report.checks.last.hint, 'Details are hidden.');
    expect(report.checks.last.summary.contains('tws_'), isFalse);
    expect(report.checks.last.hint.contains('/etc/'), isFalse);
    api.close();
  });

  testWidgets('parent sees check rows without leaked paths', (tester) async {
    final session = AppSession(
      store: InMemoryCredentialStore(),
      familyApi: FamilyApiClient(
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'overall': 'ok',
              'checked_at': '2026-11-10T12:00:00Z',
              'cached': true,
              'checks': [
                {
                  'id': 'disk',
                  'title': 'Disk space',
                  'status': 'ok',
                  'summary': 'Plenty of free space (40 GB free).',
                  'hint': '',
                  'checked_at': '2026-11-10T12:00:00Z',
                },
                {
                  'id': 'jellyfin',
                  'title': 'Movies and TV',
                  'status': 'not_installed',
                  'summary': 'Not installed.',
                  'hint': 'This is optional. Nothing to fix.',
                  'checked_at': '2026-11-10T12:00:00Z',
                },
              ],
            }),
            200,
          );
        }),
      ),
    );
    session.enrollment = _bundle('parent');
    session.profile = _profile('parent');

    await tester.pumpWidget(MaterialApp(home: HealthScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('Everything checked is working.'), findsOneWidget);
    expect(find.text('Disk space'), findsOneWidget);
    expect(find.text('Not installed'), findsOneWidget);
    expect(find.textContaining('127.0.0.1'), findsNothing);
    expect(find.textContaining('/etc/'), findsNothing);
  });

  testWidgets('kid does not load health', (tester) async {
    var called = false;
    final session = AppSession(
      store: InMemoryCredentialStore(),
      familyApi: FamilyApiClient(
        client: MockClient((request) async {
          called = true;
          return http.Response('no', 500);
        }),
      ),
    );
    session.enrollment = _bundle('kid');
    session.profile = _profile('kid');

    await tester.pumpWidget(MaterialApp(home: HealthScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('Only parents can check the home.'), findsOneWidget);
    expect(called, isFalse);
  });
}
