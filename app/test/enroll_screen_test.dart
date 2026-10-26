import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/enroll/enroll_screen.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

void main() {
  testWidgets('manual code enrollment path', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.contains('well-known')) {
        return http.Response(
          jsonEncode({'enroll_url': '/family/api/app/enroll'}),
          200,
        );
      }
      if (request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'device_id': 'd1',
            'username': 'kid1',
            'role': 'kid',
            'mxid': '@kid1:family.example',
            'dashboard': {'token': 'tok', 'api_base': '/family/api'},
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/app/me')) {
        return http.Response(
          jsonEncode({
            'username': 'kid1',
            'role': 'kid',
            'mxid': '@kid1:family.example',
            'quiet_hours': {'configured': false, 'active': false},
            'events_enabled': true,
          }),
          200,
        );
      }
      return http.Response('', 404);
    });

    final session = AppSession(
      store: InMemoryCredentialStore(),
      discovery: DiscoveryClient(client: client),
      familyApi: FamilyApiClient(client: client),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EnrollScreen(
          session: session,
          qrScannerBuilder: ({required onDetect}) => const SizedBox.shrink(),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'family.example');
    await tester.enterText(find.byType(TextField).at(1), 'CODE123');
    await tester.tap(find.text('Enroll this device'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(session.route, AppRoute.home);
    expect(session.profile?.username, 'kid1');
  });

  testWidgets('bare family name enrolls against tinyweb.win', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.contains('well-known')) {
        expect(
          request.url.toString(),
          'https://smith.tinyweb.win/.well-known/tinywebstack-family.json',
        );
        return http.Response(
          jsonEncode({'enroll_url': '/family/api/app/enroll'}),
          200,
        );
      }
      if (request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'device_id': 'd1',
            'username': 'kid1',
            'role': 'kid',
            'mxid': '@kid1:smith.tinyweb.win',
            'dashboard': {'token': 'tok', 'api_base': '/family/api'},
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/app/me')) {
        return http.Response(
          jsonEncode({
            'username': 'kid1',
            'role': 'kid',
            'mxid': '@kid1:smith.tinyweb.win',
            'quiet_hours': {'configured': false, 'active': false},
            'events_enabled': true,
          }),
          200,
        );
      }
      return http.Response('', 404);
    });

    final session = AppSession(
      store: InMemoryCredentialStore(),
      discovery: DiscoveryClient(client: client),
      familyApi: FamilyApiClient(client: client),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EnrollScreen(
          session: session,
          qrScannerBuilder: ({required onDetect}) => const SizedBox.shrink(),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'smith');
    await tester.enterText(find.byType(TextField).at(1), 'CODE123');
    await tester.tap(find.text('Enroll this device'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(session.route, AppRoute.home);
    expect(session.profile?.username, 'kid1');
  });
}
