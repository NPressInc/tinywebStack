import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/enroll/enroll_screen.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

void _tallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('manual code enrollment path', (tester) async {
    _tallSurface(tester);
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

    expect(session.route, AppRoute.setupReady);
    await session.continueFromSetupChecklist();
    expect(session.route, AppRoute.home);
    expect(session.profile?.username, 'kid1');
  });

  testWidgets('bare family name enrolls against tinyweb.win', (tester) async {
    _tallSurface(tester);
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

    expect(session.route, AppRoute.setupReady);
    await session.continueFromSetupChecklist();
    expect(session.route, AppRoute.home);
    expect(session.profile?.username, 'kid1');
  });

  testWidgets('join link fills the server and enrolls', (tester) async {
    _tallSurface(tester);
    String? posted;
    final client = MockClient((request) async {
      if (request.url.path.contains('well-known')) {
        return http.Response(
          jsonEncode({
            'server_name': 'smith.tinyweb.win',
            'enroll_url': '/family/api/app/enroll',
          }),
          200,
        );
      }
      if (request.method == 'POST') {
        posted = request.body;
        return http.Response(
          jsonEncode({
            'device_id': 'd1',
            'username': 'kid1',
            'role': 'kid',
            'mxid': '@kid1:smith.tinyweb.win',
            'server_name': 'smith.tinyweb.win',
            'dashboard': {'token': 'tok', 'api_base': '/family/api'},
            'matrix': {'status': 'ok', 'access_token': 'm', 'device_id': 'MX'},
            'caldav': {
              'root': 'https://nextcloud.smith.tinyweb.win/remote.php/dav',
              'username': 'kid1',
              'password': 'app-pass',
            },
            'mobilizon': {'status': 'password_required'},
            'owntracks': {'status': 'not_needed'},
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
          initialLink: 'https://smith.tinyweb.win/family/join#code=CODE123',
          qrScannerBuilder: ({required onDetect}) => const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(posted, contains('"code":"CODE123"'));
    expect(posted, isNot(contains('password')));
    expect(session.route, AppRoute.setupReady);
  });

  testWidgets('scanner link enrolls without an extra tap', (tester) async {
    _tallSurface(tester);
    final client = MockClient((request) async {
      if (request.url.path.contains('well-known')) {
        return http.Response(
          jsonEncode({
            'server_name': 'smith.tinyweb.win',
            'enroll_url': '/family/api/app/enroll',
          }),
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
          qrScannerBuilder: ({required onDetect}) => TextButton(
            onPressed: () => onDetect(
              'https://smith.tinyweb.win/family/join#code=SCAN99',
            ),
            child: const Text('Fake scan'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Fake scan'));
    await tester.pumpAndSettle();
    expect(session.route, AppRoute.setupReady);
    expect(find.text('Family server'), findsOneWidget);
  });

  testWidgets('expired, used, wrong server, and unreachable are explained', (tester) async {
    _tallSurface(tester);
    Future<void> show(http.Client client, String server) async {
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
      await tester.enterText(find.byType(TextField).at(0), server);
      await tester.enterText(find.byType(TextField).at(1), 'CODE123');
      await tester.tap(find.text('Enroll this device'));
      await tester.pump();
      await tester.pumpAndSettle();
    }

    await show(
      MockClient((request) async {
        if (request.url.path.contains('well-known')) {
          return http.Response(
            jsonEncode({'enroll_url': '/family/api/app/enroll'}),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'error': 'code_expired',
            'message':
                'This code has expired. Ask a parent for a new one. Codes last about 10 minutes.',
          }),
          401,
        );
      }),
      'family.example',
    );
    expect(find.textContaining('This code has expired'), findsOneWidget);

    await show(
      MockClient((request) async {
        if (request.url.path.contains('well-known')) {
          return http.Response(
            jsonEncode({'enroll_url': '/family/api/app/enroll'}),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'error': 'code_used',
            'message': 'This code was already used. Ask a parent for a new one.',
          }),
          401,
        );
      }),
      'family.example',
    );
    expect(find.textContaining('already used'), findsOneWidget);

    var posted = false;
    await show(
      MockClient((request) async {
        if (request.method == 'POST') {
          posted = true;
        }
        return http.Response(
          jsonEncode({'server_name': 'other.example', 'enroll_url': '/family/api/app/enroll'}),
          200,
        );
      }),
      'family.example',
    );
    expect(posted, isFalse);
    expect(find.textContaining('other.example'), findsOneWidget);

    await show(
      MockClient((request) async {
        throw const SocketException('down');
      }),
      'smith.tinyweb.win',
    );
    expect(find.textContaining("Can't reach the family box"), findsOneWidget);
    expect(find.textContaining('smith.tinyweb.win'), findsWidgets);
  });
}
