import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';

FamilyDiscovery _discovery({String? enrollUrl, bool missingEnrollUrl = false}) {
  return FamilyDiscovery(
    serverOrigin: 'https://family.example',
    enrollUrl: missingEnrollUrl ? null : (enrollUrl ?? '/family/api/app/enroll'),
    serverName: 'family.example',
  );
}

void main() {
  test('discovery parses well-known JSON', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/.well-known/tinywebstack-family.json');
      return http.Response(
        jsonEncode({
          'server_name': 'family.example',
          'enroll_url': '/family/api/app/enroll',
        }),
        200,
      );
    });

    final discovery = DiscoveryClient(client: client);
    final result = await discovery.fetch('https://family.example');
    expect(result.serverName, 'family.example');
    expect(result.resolveEnrollEndpoint(),
        'https://family.example/family/api/app/enroll');
  });

  test('enroll success', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'device_id': 'd1',
          'username': 'kid1',
          'role': 'kid',
          'mxid': '@kid1:family.example',
          'server_name': 'family.example',
          'dashboard': {'token': 'tok', 'api_base': '/family/api'},
        }),
        200,
      );
    });

    final api = FamilyApiClient(client: client);
    final bundle = await api.enroll(
      discovery: _discovery(),
      method: 'code',
      code: 'ABC',
    );
    expect(bundle.dashboardToken, 'tok');
    expect(bundle.mxid, '@kid1:family.example');
  });

  test('enroll errors', () async {
    Future<http.Response> resp(int code, [Map<String, dynamic>? body]) async {
      return http.Response(jsonEncode(body ?? {'error': 'x'}), code);
    }

    final api401 = FamilyApiClient(
      client: MockClient((_) => resp(401, {'error': 'invalid_credentials'})),
    );
    await expectLater(
      api401.enroll(discovery: _discovery(), method: 'code', code: 'x'),
      throwsA(isA<EnrollException>()),
    );

    final api403 = FamilyApiClient(
      client: MockClient((_) => resp(403)),
    );
    await expectLater(
      api403.enroll(discovery: _discovery(), method: 'code', code: 'x'),
      throwsA(
        predicate<EnrollException>((e) => e.kind == EnrollErrorKind.notFamilyMember),
      ),
    );

    final api429 = FamilyApiClient(
      client: MockClient((_) => resp(429)),
    );
    await expectLater(
      api429.enroll(discovery: _discovery(), method: 'code', code: 'x'),
      throwsA(
        predicate<EnrollException>((e) => e.kind == EnrollErrorKind.rateLimited),
      ),
    );
  });

  test('missing enroll_url', () async {
    final api = FamilyApiClient(client: MockClient((_) async => http.Response('', 200)));
    await expectLater(
      api.enroll(
        discovery: _discovery(missingEnrollUrl: true),
        method: 'code',
        code: 'x',
      ),
      throwsA(
        predicate<EnrollException>((e) => e.kind == EnrollErrorKind.needsUpdate),
      ),
    );
  });

  test('fetchMe 401', () async {
    final client = MockClient((_) async => http.Response('', 401));
    final api = FamilyApiClient(client: client);
    final bundle = EnrollmentBundle(
      deviceId: 'd',
      username: 'u',
      role: 'parent',
      mxid: '@u:x',
      serverName: 'x',
      dashboardToken: 'bad',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: _discovery(),
    );
    await expectLater(
      api.fetchMe(bundle),
      throwsA(isA<EnrollException>()),
    );
  });
}
