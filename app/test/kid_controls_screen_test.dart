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

FamilyApiClient _fakeApi({
  List<Map<String, dynamic>>? putBodies,
  List<Map<String, dynamic>>? linkedFamilies,
}) {
  final linked = linkedFamilies ?? <Map<String, dynamic>>[];
  return FamilyApiClient(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/invites')) {
        return http.Response(jsonEncode([]), 200);
      }
      if (request.url.path.contains('/trusted-domains/') &&
          request.method == 'DELETE') {
        linked.clear();
        return http.Response('{}', 200);
      }
      if (request.url.path.endsWith('/linked-families')) {
        return http.Response(
          jsonEncode({'linked_families': List<Map<String, dynamic>>.from(linked)}),
          200,
        );
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
          putBodies?.add(body);
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

Widget _kidDetailApp({
  required AppSession session,
  required FamilyApiClient api,
}) {
  return MaterialApp(
    home: KidDetailScreen(
      session: session,
      kid: FamilyMember(
        username: 'kid1',
        mxid: '@kid1:family.example',
        role: 'kid',
        displayName: 'Kid One',
      ),
      api: api,
    ),
  );
}

Future<void> _pumpKidDetail(
  WidgetTester tester, {
  List<Map<String, dynamic>>? putBodies,
}) async {
  await tester.pumpWidget(
    _kidDetailApp(
      session: _parentSession(),
      api: _fakeApi(putBodies: putBodies),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _quietHoursSwitch(WidgetTester tester) {
  return find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is SwitchListTile && w.title is Text &&
          (w.title as Text).data == 'Pause messages overnight',
    ),
    matching: find.byType(Switch),
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

  testWidgets('parent unlinks linked family domain', (tester) async {
    final linked = [
      {
        'domain': 'jones.family.test',
        'family_name': 'Jones Family',
      },
    ];
    String? deletedPath;
    final api = FamilyApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/invites')) {
          return http.Response(jsonEncode([]), 200);
        }
        if (request.url.path.contains('/trusted-domains/') &&
            request.method == 'DELETE') {
          deletedPath = request.url.path;
          linked.clear();
          return http.Response('{}', 200);
        }
        if (request.url.path.endsWith('/linked-families')) {
          return http.Response(
            jsonEncode({'linked_families': List.from(linked)}),
            200,
          );
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
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: KidControlsScreen(
          session: _parentSession(),
          api: api,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('jones.family.test'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('unlink-domain-jones.family.test')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Unlink jones.family.test?'), findsOneWidget);
    await tester.tap(find.text('Unlink'));
    await tester.pumpAndSettle();

    expect(
      deletedPath,
      '/family/api/trusted-domains/jones.family.test',
    );
    expect(find.text('Unlinked jones.family.test'), findsOneWidget);
    expect(find.text('jones.family.test'), findsNothing);
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

  testWidgets('enabling quiet hours defaults to America/Denver window',
      (tester) async {
    final putBodies = <Map<String, dynamic>>[];
    await _pumpKidDetail(tester, putBodies: putBodies);

    await tester.tap(_quietHoursSwitch(tester));
    await tester.pumpAndSettle();

    expect(putBodies, isNotEmpty);
    final qh = putBodies.last['quiet_hours'] as Map<String, dynamic>;
    expect(qh['start'], '21:00');
    expect(qh['end'], '07:00');
    expect(qh['timezone'], 'America/Denver');
    expect(find.text('9:00 PM (21:00)'), findsOneWidget);
    expect(find.text('7:00 AM (07:00)'), findsOneWidget);
  });

  testWidgets('quiet hours start picker saves immediately on confirm',
      (tester) async {
    final putBodies = <Map<String, dynamic>>[];
    await _pumpKidDetail(tester, putBodies: putBodies);

    await tester.tap(_quietHoursSwitch(tester));
    await tester.pumpAndSettle();
    putBodies.clear();

    await tester.tap(find.byKey(const Key('quiet-hours-start')));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(putBodies, isNotEmpty);
    final qh = putBodies.last['quiet_hours'] as Map<String, dynamic>;
    expect(qh['start'], '21:00');
  });

  testWidgets('quiet hours timezone sheet saves immediately', (tester) async {
    final putBodies = <Map<String, dynamic>>[];
    await _pumpKidDetail(tester, putBodies: putBodies);

    await tester.tap(_quietHoursSwitch(tester));
    await tester.pumpAndSettle();
    putBodies.clear();

    await tester.tap(find.byKey(const Key('quiet-hours-timezone')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('America/New_York'));
    await tester.pumpAndSettle();

    expect(putBodies, isNotEmpty);
    final qh = putBodies.last['quiet_hours'] as Map<String, dynamic>;
    expect(qh['timezone'], 'America/New_York');
  });
}
