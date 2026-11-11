import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/setup/setup_client.dart';
import 'package:tinyweb/src/setup/setup_discovery.dart';
import 'package:tinyweb/src/setup/unbox_screen.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

void _tallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Map<String, dynamic> _status({
  required String phase,
  String? error,
  String? enrollOrigin,
  String certificateState = 'pending',
  String certificateDetail = '',
}) {
  return {
    'phase': phase,
    'provisioned': phase == 'ready',
    'code_required': true,
    'family_slug': phase == 'waiting' ? null : 'floyd',
    'domain': phase == 'waiting' ? null : 'floyd.tinyweb.win',
    'parent_username': phase == 'waiting' ? null : 'william',
    'enroll_origin': enrollOrigin,
    'error': error,
    'steps': [
      {'id': 'account', 'label': 'Name the family', 'state': 'done', 'detail': ''},
      {'id': 'install', 'label': 'Install TinyWeb', 'state': 'done', 'detail': ''},
      {
        'id': 'certificate',
        'label': 'Get a real Let\'s Encrypt certificate',
        'state': certificateState,
        'detail': certificateDetail,
      },
      {
        'id': 'tunnel',
        'label': 'Open a path to the internet',
        'state': phase == 'ready' ? 'done' : 'blocked',
        'detail': phase == 'ready'
            ? 'The internet path is open.'
            : 'TinyWeb will open its own path to the internet so you do not change the router. That step is not running yet.',
      },
      {
        'id': 'ready',
        'label': 'Ready for the family',
        'state': phase == 'ready' ? 'done' : 'pending',
        'detail': '',
      },
    ],
  };
}

Future<void> _fillForm(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('unbox-setup-code')), 'box-setup-code-22');
  await tester.enterText(find.byKey(const Key('unbox-family-name')), 'Floyd');
  await tester.enterText(find.byKey(const Key('unbox-parent-name')), 'William');
  await tester.enterText(find.byKey(const Key('unbox-password')), 'correct-horse');
  await tester.enterText(find.byKey(const Key('unbox-password-confirm')), 'correct-horse');
}

void main() {
  testWidgets('no box on the Wi-Fi can still open existing enrollment', (tester) async {
    _tallSurface(tester);
    final session = AppSession(store: InMemoryCredentialStore());
    await tester.pumpWidget(
      MaterialApp(
        home: UnboxScreen(
          session: session,
          locator: FakeSetupLocator(null),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Plug in power and ethernet'), findsWidgets);
    await tester.tap(find.text('Join a family that is already set up'));
    expect(session.route, AppRoute.enroll);
  });

  testWidgets('scanned code is filled in and a blocked box does not sign in', (tester) async {
    _tallSurface(tester);
    Map<String, dynamic>? posted;
    final setupHttp = MockClient((request) async {
      if (request.method == 'POST') {
        posted = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(
            _status(
              phase: 'blocked',
              certificateState: 'blocked',
              certificateDetail:
                  'TinyWeb will get a real Let\'s Encrypt certificate for floyd.tinyweb.win. That step is not running yet, so setup stops here instead of showing a certificate warning.',
            ),
          ),
          200,
        );
      }
      return http.Response(jsonEncode(_status(phase: 'blocked')), 200);
    });
    final session = AppSession(store: InMemoryCredentialStore());
    await tester.pumpWidget(
      MaterialApp(
        home: UnboxScreen(
          session: session,
          initialCode: 'https://tinyweb.win/setup#code=box-setup-code-22',
          client: SetupClient(
            baseUri: Uri.parse('http://tinyweb.local:4734'),
            client: setupHttp,
          ),
          pollInterval: const Duration(days: 1),
        ),
      ),
    );

    expect(
      tester.widget<TextField>(find.byKey(const Key('unbox-setup-code'))).controller?.text,
      'https://tinyweb.win/setup#code=box-setup-code-22',
    );
    await _fillForm(tester);
    await tester.tap(find.byKey(const Key('unbox-submit')));
    await tester.pump();
    await tester.pump();

    expect(posted?['code'], 'box-setup-code-22');
    expect(posted?['family_name'], 'Floyd');
    expect(posted?['password'], 'correct-horse');
    expect(find.textContaining("Let's Encrypt"), findsWidgets);
    expect(find.textContaining('certificate warning'), findsOneWidget);
    expect(find.textContaining('router'), findsWidgets);
    expect(session.enrollment, isNull);
    expect(session.route, isNot(AppRoute.home));
    expect(find.text('You\'re all set'), findsNothing);
  });

  testWidgets('certificate wait says the secure connection is still being set up', (
    tester,
  ) async {
    _tallSurface(tester);
    final setupHttp = MockClient((request) async {
      return http.Response(
        jsonEncode(
          _status(
            phase: 'installing',
            certificateState: 'current',
            certificateDetail: 'Still setting up your secure connection.',
          ),
        ),
        200,
      );
    });
    final session = AppSession(store: InMemoryCredentialStore());
    await tester.pumpWidget(
      MaterialApp(
        home: UnboxScreen(
          session: session,
          client: SetupClient(
            baseUri: Uri.parse('http://tinyweb.local:4734'),
            client: setupHttp,
          ),
          pollInterval: const Duration(days: 1),
        ),
      ),
    );
    await _fillForm(tester);
    await tester.tap(find.byKey(const Key('unbox-submit')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Still setting up your secure connection.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('You\'re all set'), findsNothing);
    expect(session.route, isNot(AppRoute.home));
    expect(session.enrollment, isNull);
  });

  testWidgets('a blocked certificate can be tried again with the same code', (
    tester,
  ) async {
    _tallSurface(tester);
    final session = AppSession(store: InMemoryCredentialStore());
    await tester.pumpWidget(
      MaterialApp(
        home: UnboxScreen(
          session: session,
          client: SetupClient(
            baseUri: Uri.parse('http://tinyweb.local:4734'),
            client: MockClient((request) async {
              return http.Response(
                jsonEncode(
                  _status(
                    phase: 'blocked',
                    certificateState: 'blocked',
                    certificateDetail:
                        'TinyWeb does not have a real Let\'s Encrypt certificate for floyd.tinyweb.win yet, so setup stops here instead of showing a certificate warning. You can try again with the same setup code.',
                  ),
                ),
                200,
              );
            }),
          ),
          pollInterval: const Duration(days: 1),
        ),
      ),
    );
    await _fillForm(tester);
    await tester.tap(find.byKey(const Key('unbox-submit')));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('same setup code'), findsOneWidget);
    expect(session.enrollment, isNull);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(find.byKey(const Key('unbox-setup-code')), findsOneWidget);
    expect(find.text('You\'re all set'), findsNothing);
    expect(session.route, isNot(AppRoute.home));
  });

  testWidgets('ready box signs the parent in with the password they chose', (tester) async {
    _tallSurface(tester);
    final familyHttp = MockClient((request) async {
      if (request.url.path.contains('well-known')) {
        expect(request.url.host, 'floyd.tinyweb.win');
        return http.Response(
          jsonEncode({'enroll_url': '/family/api/app/enroll'}),
          200,
        );
      }
      if (request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['username'], 'william');
        expect(body['password'], 'correct-horse');
        return http.Response(
          jsonEncode({
            'device_id': 'd1',
            'username': 'william',
            'role': 'parent',
            'mxid': '@william:floyd.tinyweb.win',
            'dashboard': {'token': 'tok', 'api_base': '/family/api'},
          }),
          200,
        );
      }
      return http.Response('', 404);
    });
    final session = AppSession(
      store: InMemoryCredentialStore(),
      discovery: DiscoveryClient(client: familyHttp),
      familyApi: FamilyApiClient(client: familyHttp),
    );
    final setupHttp = MockClient((request) async {
      return http.Response(
        jsonEncode(
          _status(
            phase: 'ready',
            enrollOrigin: 'https://floyd.tinyweb.win',
            certificateState: 'done',
            certificateDetail: 'Let\'s Encrypt certificate is in place.',
          ),
        ),
        200,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: UnboxScreen(
          session: session,
          client: SetupClient(
            baseUri: Uri.parse('http://tinyweb.local:4734'),
            client: setupHttp,
          ),
          locator: FakeSetupLocator(const DiscoveredBox(ip: '192.168.1.20', port: 4734)),
        ),
      ),
    );
    await _fillForm(tester);
    await tester.tap(find.byKey(const Key('unbox-submit')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(session.route, AppRoute.setupReady);
    expect(session.enrollment?.username, 'william');
    expect(session.enrollment?.role, 'parent');
  });
}
