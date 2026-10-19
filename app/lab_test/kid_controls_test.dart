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
      'kid controls e2e (skipped — set TW_HS)',
      () {},
      skip: 'TW_HS not set',
    );
    return;
  }

  test('parent edits kid events and quiet hours', () async {
    final password = Platform.environment['TW_TEST_PASSWORD'];
    if (password == null || password.isEmpty) {
      fail('TW_TEST_PASSWORD must be set');
    }
    final kidUser = Platform.environment['TW_KID_USER'] ?? 'kid';
    final parentUser = Platform.environment['TW_PARENT_USER'] ?? 'parent';
    final httpClient = tlsHttpClientFromEnvironment();
    final discovery = await DiscoveryClient(client: httpClient).fetch(origin);
    final api = FamilyApiClient(client: httpClient);

    final parentBundle = await api.enroll(
      discovery: discovery,
      method: 'password',
      username: parentUser,
      password: password,
      deviceName: 'tw_kid_controls_lab_parent',
    );

    final original = await api.fetchKidPermissions(parentBundle, kidUser);
    final eventsWas = original.eventsEnabled;
    final quietWas = original.quietHours;

    final toggledEvents = !eventsWas;
    await api.updateKidPermissions(
      parentBundle,
      kidUser,
      {'events_enabled': toggledEvents},
    );
    final afterEvents = await api.fetchKidPermissions(parentBundle, kidUser);
    expect(afterEvents.eventsEnabled, toggledEvents);

    const labQuiet = {
      'start': '22:30',
      'end': '06:45',
      'timezone': 'UTC',
      'days': [0, 1, 2, 3, 4, 5, 6],
    };
    await api.updateKidPermissions(
      parentBundle,
      kidUser,
      {'quiet_hours': labQuiet},
    );
    final afterQuiet = await api.fetchKidPermissions(parentBundle, kidUser);
    expect(afterQuiet.quietHours?.start, '22:30');
    expect(afterQuiet.quietHours?.end, '06:45');

    final restoreBody = <String, dynamic>{
      'events_enabled': eventsWas,
    };
    if (quietWas != null && quietWas.isConfigured) {
      restoreBody['quiet_hours'] = quietWas.toJson();
    } else {
      restoreBody['revoke'] = ['quiet_hours'];
    }
    await api.updateKidPermissions(parentBundle, kidUser, restoreBody);
    final restored = await api.fetchKidPermissions(parentBundle, kidUser);
    expect(restored.eventsEnabled, eventsWas);
    if (quietWas != null && quietWas.isConfigured) {
      expect(restored.quietHours?.start, quietWas.start);
      expect(restored.quietHours?.end, quietWas.end);
    } else {
      expect(restored.quietHoursEnabled, isFalse);
    }

    await _revokeDevice(httpClient, parentBundle);
    api.close();
    httpClient.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<void> _revokeDevice(http.Client client, EnrollmentBundle bundle) async {
  final base = bundle.serverOrigin.endsWith('/')
      ? bundle.serverOrigin.substring(0, bundle.serverOrigin.length - 1)
      : bundle.serverOrigin;
  final path = bundle.apiBase.startsWith('/')
      ? bundle.apiBase
      : '/${bundle.apiBase}';
  final url = '$base$path/app/devices/${bundle.deviceId}/revoke';
  final resp = await client.post(
    Uri.parse(url),
    headers: {'Authorization': 'Bearer ${bundle.dashboardToken}'},
  );
  expect(resp.statusCode, 200);
}
