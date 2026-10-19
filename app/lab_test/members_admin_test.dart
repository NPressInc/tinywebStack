import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/api/tls_http_client.dart';

import 'lab_env.dart';

void main() {
  installLabTestHttpOverrides();
  final origin = Platform.environment['TW_HS'];
  if (origin == null || origin.isEmpty) {
    test(
      'members admin e2e (skipped — set TW_HS)',
      () {},
      skip: 'TW_HS not set',
    );
    return;
  }

  test('parent members invites lifecycle', () async {
    final password = Platform.environment['TW_TEST_PASSWORD'];
    if (password == null || password.isEmpty) {
      fail('TW_TEST_PASSWORD must be set');
    }
    final parentUser = Platform.environment['TW_PARENT_USER'] ?? 'parent';
    final httpClient = tlsHttpClientFromEnvironment();
    final discovery = await DiscoveryClient(client: httpClient).fetch(origin);
    final api = FamilyApiClient(client: httpClient);

    final parentBundle = await api.enroll(
      discovery: discovery,
      method: 'password',
      username: parentUser,
      password: password,
      deviceName: 'tw_members_lab_parent',
    );

    final suffix = DateTime.now().millisecondsSinceEpoch % 10000000;
    final labKid = 'labm$suffix';
    String? inviteNonce;

    try {
      final created = await api.createMember(
        parentBundle,
        username: labKid,
        role: 'kid',
        displayName: 'Lab Member',
        issueEnrollCode: true,
      );
      expect(created.password.length, greaterThanOrEqualTo(12));
      expect(created.enrollCode, isNotNull);
      expect(created.enrollQrPayload, isNotEmpty);

      final enrollCode = await api.issueMemberEnrollCode(parentBundle, labKid);
      expect(enrollCode.code, isNotEmpty);

      final devicesBefore = await api.fetchMemberDevices(parentBundle, labKid);
      expect(devicesBefore, isEmpty);

      final reset = await api.resetMemberPassword(parentBundle, labKid);
      expect(reset.password.length, greaterThanOrEqualTo(12));

      final invite = await api.createHouseholdInvite(parentBundle);
      inviteNonce = invite.nonce;
      expect(invite.inviteUrl, contains('redeem?token='));

      final pending = await api.fetchInvites(parentBundle);
      expect(pending.any((i) => i.nonce == inviteNonce), isTrue);

      await api.deleteHouseholdInvite(parentBundle, inviteNonce);
      inviteNonce = null;

      await api.deleteMember(parentBundle, labKid);
    } finally {
      if (inviteNonce != null) {
        try {
          await api.deleteHouseholdInvite(parentBundle, inviteNonce);
        } catch (_) {}
      }
      try {
        await api.deleteMember(parentBundle, labKid);
      } catch (_) {}
      await _revokeDevice(httpClient, parentBundle);
      api.close();
      httpClient.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<void> _revokeDevice(http.Client client, EnrollmentBundle bundle) async {
  final b = bundle;
  final base = b.serverOrigin.endsWith('/')
      ? b.serverOrigin.substring(0, b.serverOrigin.length - 1)
      : b.serverOrigin;
  final path = b.apiBase.startsWith('/') ? b.apiBase : '/${b.apiBase}';
  final url = '$base$path/app/devices/${b.deviceId}/revoke';
  final resp = await client.post(
    Uri.parse(url),
    headers: {'Authorization': 'Bearer ${b.dashboardToken}'},
  );
  expect(resp.statusCode, 200);
}
