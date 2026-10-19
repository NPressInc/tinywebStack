import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/tls_http_client.dart';
import 'package:tinyweb/src/location/map_config_policy.dart';

import 'lab_env.dart';

void main() {
  installLabTestHttpOverrides();
  final origin = Platform.environment['TW_HS'];
  if (origin == null || origin.isEmpty) {
    test(
      'map tiles e2e (skipped — set TW_HS)',
      () {},
      skip: 'TW_HS not set',
    );
    return;
  }

  test('parent map config and PMTiles range header', () async {
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
      deviceName: 'tw_map_lab_parent',
    );
    final mapConfig = await api.fetchMapConfig(bundle);
    expect(
      familyMapConfigUsesBoxOriginOnly(mapConfig, bundle),
      isTrue,
      reason: 'map URLs must not point off-box',
    );
    if (!mapConfig.available) {
      return;
    }
    final head = await httpClient.head(
      Uri.parse(mapConfig.tilesUrl),
      headers: {'Authorization': 'Bearer ${bundle.dashboardToken}'},
    );
    expect(head.statusCode, lessThan(400));
    final range = await httpClient.get(
      Uri.parse(mapConfig.tilesUrl),
      headers: {
        'Authorization': 'Bearer ${bundle.dashboardToken}',
        'Range': 'bytes=0-127',
      },
    );
    expect(range.statusCode, anyOf(200, 206));
    expect(range.bodyBytes.length, greaterThan(0));
  });
}
