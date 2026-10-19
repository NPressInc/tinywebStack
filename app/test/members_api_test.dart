import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';

EnrollmentBundle _bundle() => EnrollmentBundle(
      deviceId: 'd',
      username: 'parent1',
      role: 'parent',
      mxid: '@parent1:family.example',
      serverName: 'family.example',
      dashboardToken: 'tok',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: FamilyDiscovery(
        serverOrigin: 'https://family.example',
        enrollUrl: '/family/api/app/enroll',
      ),
    );

void main() {
  test('create member parses password and enroll payload', () async {
    final api = FamilyApiClient(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/family/api/members');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['username'], 'sam');
        expect(body['issue_enroll_code'], true);
        return http.Response(
          jsonEncode({
            'username': 'sam',
            'role': 'kid',
            'password': 'longpassword1234',
            'enroll_code': 'ABC',
            'enroll_qr_payload': 'tinyweb://enroll?server=family.example&code=ABC',
          }),
          200,
        );
      }),
    );
    final result = await api.createMember(
      _bundle(),
      username: 'sam',
      role: 'kid',
      displayName: 'Sam',
    );
    expect(result.password, 'longpassword1234');
    expect(result.enrollCode, 'ABC');
    api.close();
  });

  test('delete member surfaces server detail message', () async {
    final api = FamilyApiClient(
      client: MockClient((request) async {
        return http.Response(
          jsonEncode({'detail': 'You cannot remove your own account here'}),
          400,
        );
      }),
    );
    await expectLater(
      api.deleteMember(_bundle(), 'parent1'),
      throwsA(
        predicate<EnrollException>(
          (e) =>
              e.kind == EnrollErrorKind.server &&
              e.message!.contains('cannot remove your own'),
        ),
      ),
    );
    api.close();
  });

  test('invites create and list', () async {
    final api = FamilyApiClient(
      client: MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'token': 't',
              'nonce': 'n1',
              'invite_url': 'https://family.example/family/invite/redeem?token=t',
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode([
            {'nonce': 'n1', 'issuer': 'family.example', 'created_by': 'parent1'},
          ]),
          200,
        );
      }),
    );
    final created = await api.createHouseholdInvite(_bundle());
    expect(created.nonce, 'n1');
    final list = await api.fetchInvites(_bundle());
    expect(list, hasLength(1));
    expect(list.first.nonce, 'n1');
    api.close();
  });
}
