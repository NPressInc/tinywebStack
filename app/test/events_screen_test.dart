import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/events/events_screen.dart';
import 'package:tinyweb/src/events/events_service.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      eventsUrl: 'https://mobilizon.family.example',
      enrollUrl: '/family/api/app/enroll',
    );

EnrollmentBundle _bundle({Map<String, dynamic>? mobilizonRaw}) =>
    EnrollmentBundle(
      deviceId: 'd',
      username: 'parent',
      role: 'parent',
      mxid: '@parent:family.example',
      serverName: 'family.example',
      dashboardToken: 'tok',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: _discovery(),
      rawJson: {
        'mobilizon': mobilizonRaw ??
            {
              'status': 'ok',
              'api_url': 'https://mobilizon.family.example/api',
              'access_token': 'mob-tok',
            },
      },
    );

AppSession _session() {
  final session = AppSession(store: InMemoryCredentialStore());
  session.enrollment = _bundle();
  session.profile = AppMeProfile(
    username: 'parent',
    role: 'parent',
    mxid: '@parent:family.example',
    quietHours: QuietHoursInfo(configured: false, active: false),
    eventsEnabled: true,
  );
  session.route = AppRoute.home;
  return session;
}

Future<http.Response> _mockMobilizonResponse(http.Request request) async {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  final query = body['query'] as String;
  if (query.contains('mutation Login')) {
    return http.Response(
      jsonEncode({
        'data': {
          'login': {
            'accessToken': 'linked-mob-tok',
            'refreshToken': 'linked-refresh',
          },
        },
      }),
      200,
    );
  }
  if (query.contains('loggedUser')) {
      return http.Response(
        jsonEncode({
          'data': {
            'loggedUser': {
              'id': 'u1',
              'defaultActor': {'id': 'actor1'},
            },
          },
        }),
        200,
      );
    }
    if (query.contains('searchEvents')) {
      return http.Response(
        jsonEncode({
          'data': {
            'searchEvents': {
              'total': 1,
              'elements': [
                {
                  'id': 'ev1',
                  'uuid': 'uuid-1',
                  'title': 'Block party',
                  'beginsOn': '2030-06-01T18:00:00Z',
                  'endsOn': '2030-06-01T20:00:00Z',
                  'organizerActor': {'id': 'a1', 'name': 'Parent'},
                  'attributedTo': {'id': 'a1', 'name': 'Parent'},
                  'participantStats': {'going': 2},
                },
              ],
            },
          },
        }),
        200,
      );
    }
    if (query.contains('participations')) {
      return http.Response(
        jsonEncode({
          'data': {
            'person': {
              'participations': {'elements': []},
            },
          },
        }),
        200,
      );
    }
  return http.Response(jsonEncode({'data': {}}), 200);
}

EventsService _mockService({
  EnrollmentBundle? bundle,
  CredentialStore? credentialStore,
}) {
  final mock = MockClient(_mockMobilizonResponse);
  return EventsService(
    bundle: bundle ?? _bundle(),
    httpClient: mock,
    credentialStore: credentialStore,
  );
}

void main() {
  testWidgets('events screen lists upcoming events', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EventsScreen(
          session: _session(),
          service: _mockService(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Block party'), findsOneWidget);
    expect(find.text('Events'), findsOneWidget);
  });

  testWidgets('events screen links events with family password', (tester) async {
    final store = InMemoryCredentialStore();
    final session = AppSession(store: store);
    session.enrollment = _bundle(
      mobilizonRaw: const {'status': 'password_required'},
    );
    session.profile = AppMeProfile(
      username: 'parent',
      role: 'parent',
      mxid: '@parent:family.example',
      quietHours: QuietHoursInfo(configured: false, active: false),
      eventsEnabled: true,
    );
    session.route = AppRoute.home;
    final service = _mockService(
      bundle: session.enrollment!,
      credentialStore: store,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EventsScreen(
          session: session,
          service: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign in to Events'), findsOneWidget);
    expect(find.byKey(const Key('events-link-password')), findsOneWidget);
    expect(find.text('Connect Events'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('events-link-password')),
      'family-secret',
    );
    await tester.tap(find.byKey(const Key('events-link-submit')));
    await tester.pumpAndSettle();

    expect(session.enrollment?.mobilizonCredentials?.accessToken, 'linked-mob-tok');
    final stored = await store.read();
    expect(stored?.mobilizonCredentials?.accessToken, 'linked-mob-tok');
    expect(find.text('Block party'), findsOneWidget);
  });
}
