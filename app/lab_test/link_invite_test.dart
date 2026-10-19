import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/tls_http_client.dart';

import 'lab_env.dart';

void main() {
  installLabTestHttpOverrides();
  final origin = Platform.environment['TW_HS'];
  if (origin == null || origin.isEmpty) {
    test(
      'link invite lab (skipped — set TW_HS)',
      () {},
      skip: 'TW_HS not set',
    );
    return;
  }

  test('family-b outgoing invite preview, decline, self-link reject', () async {
    final password = Platform.environment['TW_TEST_PASSWORD'];
    if (password == null || password.isEmpty) {
      fail('TW_TEST_PASSWORD must be set');
    }
    final parentUser = Platform.environment['TW_PARENT_USER'] ?? 'parent';
    final httpClient = tlsHttpClientFromEnvironment();
    final discovery = await DiscoveryClient(client: httpClient).fetch(origin);
    final api = FamilyApiClient(client: httpClient);

    final bundle = await api.enroll(
      discovery: discovery,
      method: 'password',
      username: parentUser,
      password: password,
      deviceName: 'tw_link_invite_lab',
    );

    final created = await api.createHouseholdInvite(bundle);
    expect(created.token, isNotEmpty);

    final pendingBefore = await api.fetchInvites(bundle);
    expect(pendingBefore.any((row) => row.nonce == created.nonce), isTrue);

    try {
      await api.previewLinkInvite(bundle, created.token);
      fail('expected self-link preview to be rejected');
    } catch (e) {
      expect(e.toString().toLowerCase(), contains('yourself'));
    }

    final pendingMid = await api.fetchInvites(bundle);
    expect(pendingMid.any((row) => row.nonce == created.nonce), isTrue);

    await api.declineLinkInvite(bundle, created.token);
    final pendingAfter = await api.fetchInvites(bundle);
    expect(pendingAfter.any((row) => row.nonce == created.nonce), isFalse);

    final created2 = await api.createHouseholdInvite(bundle);
    try {
      await api.acceptLinkInvite(bundle, created2.token);
      fail('expected self-link accept to be rejected');
    } catch (e) {
      expect(e.toString().toLowerCase(), contains('yourself'));
    }
    await api.deleteHouseholdInvite(bundle, created2.nonce);
  });
}
