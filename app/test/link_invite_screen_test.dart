import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/family/accept_link_invite_screen.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family-b.test',
      dashboardBase: '/family',
      enrollUrl: '/family/api/app/enroll',
    );

AppSession _session() {
  final session = AppSession(store: InMemoryCredentialStore());
  session.enrollment = EnrollmentBundle(
    deviceId: 'd',
    username: 'parent',
    role: 'parent',
    mxid: '@parent:family-b.test',
    serverName: 'family-b.test',
    dashboardToken: 'parent-token',
    apiBase: '/family/api',
    serverOrigin: 'https://family-b.test',
    discovery: _discovery(),
  );
  return session;
}

void main() {
  testWidgets('preview then accept shows result', (tester) async {
    var previewCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/link-invites/preview')) {
        previewCalls++;
        return http.Response(
          jsonEncode({
            'inviter_domain': 'family-a.test',
            'inviter_family_name': 'Family A',
            'expires_at': 2000000000,
            'already_linked': false,
            'reachable': true,
          }),
          200,
          headers: {'cache-control': 'no-store'},
        );
      }
      if (request.url.path.endsWith('/link-invites/accept')) {
        return http.Response(
          jsonEncode({
            'linked_domain': 'family-a.test',
            'synapse_federation': 'ok',
            'mobilizon_relay': 'ok',
            'already_linked': false,
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });
    final session = _session();
    final api = FamilyApiClient(client: client);

    await tester.pumpWidget(
      MaterialApp(
        home: AcceptLinkInviteScreen(session: session, api: api),
      ),
    );

    await tester.enterText(find.byType(TextField), 'invite-token-xyz');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(previewCalls, 1);
    expect(find.text('Family A'), findsOneWidget);
    expect(find.textContaining('PUBLIC events'), findsOneWidget);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(find.text('Matrix federation: ok'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('shows friendly error on expired preview', (tester) async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({'detail': 'Invite expired'}),
        400,
      );
    });
    final session = _session();
    final api = FamilyApiClient(client: client);

    await tester.pumpWidget(
      MaterialApp(
        home: AcceptLinkInviteScreen(session: session, api: api),
      ),
    );
    await tester.enterText(find.byType(TextField), 'bad');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.textContaining('expired'), findsOneWidget);
  });
}
