import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      enrollUrl: '/family/api/app/enroll',
    );

void main() {
  test('completeEnrollment saves bundle', () async {
    final store = InMemoryCredentialStore();
    final session = AppSession(
      store: store,
      discovery: DiscoveryClient(client: MockClient((_) async => http.Response('{}', 200))),
      familyApi: FamilyApiClient(client: MockClient((request) async {
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
      })),
    );

    final bundle = EnrollmentBundle(
      deviceId: 'd',
      username: 'kid1',
      role: 'kid',
      mxid: '@kid1:family.example',
      serverName: 'family.example',
      dashboardToken: 'tok',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: _discovery(),
    );

    await session.completeEnrollment(bundle);
    expect(session.route, AppRoute.home);

    final matrixBundle = EnrollmentBundle(
      deviceId: 'd',
      username: 'kid1',
      role: 'kid',
      mxid: '@kid1:family.example',
      serverName: 'family.example',
      dashboardToken: 'tok',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: _discovery(),
      rawJson: {
        'matrix': {
          'status': 'ok',
          'access_token': 't',
          'device_id': 'dev',
          'user_id': '@kid1:family.example',
          'homeserver': 'https://matrix.example',
        },
      },
    );
    await session.completeEnrollment(matrixBundle);
    expect(session.route, AppRoute.secureChats);
    expect((await store.read())?.username, 'kid1');
  });

  test('401 from me wipes store', () async {
    final store = InMemoryCredentialStore();
    await store.write(
      EnrollmentBundle(
        deviceId: 'd',
        username: 'kid1',
        role: 'kid',
        mxid: '@kid1:family.example',
        serverName: 'family.example',
        dashboardToken: 'revoked',
        apiBase: '/family/api',
        serverOrigin: 'https://family.example',
        discovery: _discovery(),
      ),
    );

    final session = AppSession(
      store: store,
      familyApi: FamilyApiClient(
        client: MockClient((_) async => http.Response('', 401)),
      ),
    );

    await session.bootstrap();
    expect(session.route, AppRoute.enroll);
    expect(await store.read(), isNull);
    expect(session.enrollBannerMessage, isNotNull);
  });
}
