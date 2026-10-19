import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/api/tls_http_client.dart';
import 'package:tinyweb/src/location/location_fix.dart';
import 'package:tinyweb/src/location/location_publisher.dart' show LocationPostResult, LocationPublisher;
import 'package:tinyweb/src/location/owntracks_payload.dart';

void main() {
  final origin = Platform.environment['TW_HS'];
  if (origin == null || origin.isEmpty) {
    test(
      'location publish e2e (skipped — set TW_HS)',
      () {},
      skip: 'TW_HS not set',
    );
    return;
  }

  test('kid publish and parent read locations', () async {
    final password = Platform.environment['TW_TEST_PASSWORD'];
    if (password == null || password.isEmpty) {
      fail('TW_TEST_PASSWORD must be set');
    }
    final kidUser = Platform.environment['TW_KID_USER'] ?? 'kid';
    final parentUser = Platform.environment['TW_PARENT_USER'] ?? 'parent';
    final httpClient = tlsHttpClientFromEnvironment();
    final discovery = await DiscoveryClient(client: httpClient).fetch(origin);
    final api = FamilyApiClient(client: httpClient);

    final kidBundle = await api.enroll(
      discovery: discovery,
      method: 'password',
      username: kidUser,
      password: password,
      deviceName: 'tw_location_lab_kid',
    );
    final creds = kidBundle.owntracksCredentials;
    expect(creds, isNotNull, reason: 'kid enrollment should include owntracks publish');

    final publisher = LocationPublisher(
      credentials: creds!,
      httpClient: httpClient,
    );
    final fixes = <LocationFix>[
      LocationFix(
        latitude: 40.0001,
        longitude: -105.0001,
        timestamp: DateTime.now().toUtc(),
        accuracyMeters: 10,
      ),
      LocationFix(
        latitude: 40.0100,
        longitude: -105.0100,
        timestamp: DateTime.now().toUtc(),
        accuracyMeters: 12,
      ),
      LocationFix(
        latitude: 40.0200,
        longitude: -105.0200,
        timestamp: DateTime.now().toUtc(),
        accuracyMeters: 15,
      ),
    ];
    for (var i = 0; i < fixes.length; i++) {
      final fix = fixes[i];
      final payload = buildOwntracksLocationPayload(
        fix: fix,
        tid: creds.tid,
        batteryLevel: 80,
        batteryState: BatteryState.discharging,
      );
      payload['tst'] = fix.epochSeconds + i;
      final result = await publisher.postPayloadForTest(payload);
      expect(result, LocationPostResult.success);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    await Future<void>.delayed(const Duration(seconds: 2));

    final parentBundle = await api.enroll(
      discovery: discovery,
      method: 'password',
      username: parentUser,
      password: password,
      deviceName: 'tw_location_lab_parent',
    );

    final locations = await api.fetchLocations(parentBundle);
    final kidRow = locations.kids.where((k) => k.username == kidUser).toList();
    expect(kidRow, isNotEmpty);
    final last = kidRow.first;
    expect(last.lat, closeTo(40.02, 0.001));
    expect(last.lon, closeTo(-105.02, 0.001));

    final track = await api.fetchKidTrack(parentBundle, kidUser, hours: 24);
    expect(track.points.length, greaterThanOrEqualTo(3));

    await _revokeDevice(httpClient, kidBundle);
    await _revokeDevice(httpClient, parentBundle);
    publisher.close();
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
