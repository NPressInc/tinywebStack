import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/location/location_fix.dart';
import 'package:tinyweb/src/location/location_publisher.dart';
import 'package:tinyweb/src/location/owntracks_payload.dart';

OwnTracksCredentials _creds() => OwnTracksCredentials(
      url: 'https://owntracks.example/recorder/pub',
      username: 'kid1',
      device: 'kid1-phone',
      password: 'pw',
      tid: 'k1',
      publish: true,
    );

LocationFix _fix({double lat = 40, double lon = -105}) => LocationFix(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.utc(2026, 1, 1, 12),
    );

void main() {
  test('POST uses basic auth and X-Limit headers', () async {
    http.Request? captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response('[]', 200);
    });
    final dir = await Directory.systemTemp.createTemp('tw_pub_');
    final publisher = LocationPublisher(
      credentials: _creds(),
      httpClient: client,
      queueDirectory: () async => dir,
    );
    final fix = _fix();
    final payload = buildOwntracksLocationPayload(
      fix: fix,
      tid: 'k1',
      batteryLevel: 50,
      batteryState: BatteryState.discharging,
    );
    await publisher.postPayloadForTest(payload);
    expect(captured, isNotNull);
    expect(captured!.headers['Authorization'], startsWith('Basic '));
    expect(captured!.headers['X-Limit-U'], 'kid1');
    expect(captured!.headers['X-Limit-D'], 'kid1-phone');
    expect(jsonDecode(captured!.body), payload);
    client.close();
    await dir.delete(recursive: true);
  });

  test('401 stops publishing and surfaces credential error', () async {
    final client = MockClient((_) async => http.Response('nope', 401));
    final dir = await Directory.systemTemp.createTemp('tw_pub_');
    final publisher = LocationPublisher(
      credentials: _creds(),
      httpClient: client,
      queueDirectory: () async => dir,
    );
    final fix = _fix();
    final payload = buildOwntracksLocationPayload(
      fix: fix,
      tid: 'k1',
      batteryLevel: 50,
      batteryState: BatteryState.discharging,
    );
    await publisher.publish(fix, payload: payload);
    expect(publisher.credentialsRejected, isTrue);
    expect(publisher.errorMessage, locationCredentialsRejectedMessage);
    client.close();
    await dir.delete(recursive: true);
  });

  test('queues on failure and flushes with retry', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      if (calls == 1) {
        return http.Response('err', 503);
      }
      return http.Response('[]', 200);
    });
    final dir = await Directory.systemTemp.createTemp('tw_pub_');
    final publisher = LocationPublisher(
      credentials: _creds(),
      httpClient: client,
      queueDirectory: () async => dir,
      clock: () => DateTime.utc(2026, 1, 1, 12),
    );
    final fix = _fix();
    final payload = buildOwntracksLocationPayload(
      fix: fix,
      tid: 'k1',
      batteryLevel: 50,
      batteryState: BatteryState.discharging,
    );
    await publisher.publish(fix, payload: payload);
    expect(await publisher.queuedCount(), 1);
    await publisher.flushQueueNow();
    expect(await publisher.queuedCount(), 0);
    expect(calls, greaterThanOrEqualTo(2));
    client.close();
    await dir.delete(recursive: true);
  });

  test('throttle skips second post within 60s and 100m', () async {
    var posts = 0;
    final client = MockClient((_) async {
      posts++;
      return http.Response('[]', 200);
    });
    final dir = await Directory.systemTemp.createTemp('tw_pub_');
    final t0 = DateTime.utc(2026, 1, 1, 12);
    var now = t0;
    final publisher = LocationPublisher(
      credentials: _creds(),
      httpClient: client,
      queueDirectory: () async => dir,
      clock: () => now,
    );
    final payload = buildOwntracksLocationPayload(
      fix: _fix(),
      tid: 'k1',
      batteryLevel: 50,
      batteryState: BatteryState.discharging,
    );
    await publisher.publish(_fix(), payload: payload);
    now = t0.add(const Duration(seconds: 10));
    await publisher.publish(_fix(lat: 40.0001, lon: -105.0001), payload: payload);
    expect(posts, 1);
    client.close();
    await dir.delete(recursive: true);
  });

  test('queue drops entries older than 7 days', () async {
    final client = MockClient((_) async => http.Response('err', 503));
    final dir = await Directory.systemTemp.createTemp('tw_pub_');
    final old = DateTime.utc(2020, 1, 1);
    final publisher = LocationPublisher(
      credentials: _creds(),
      httpClient: client,
      queueDirectory: () async => dir,
      clock: () => DateTime.utc(2026, 1, 8),
    );
    final payload = buildOwntracksLocationPayload(
      fix: _fix(),
      tid: 'k1',
      batteryLevel: 50,
      batteryState: BatteryState.discharging,
    );
    final file = File('${dir.path}/publish_queue.json');
    await file.writeAsString(jsonEncode({
      'queue': [
        {
          'payload': payload,
          'enqueued_at': old.toUtc().toIso8601String(),
        },
      ],
    }));
    await publisher.publish(_fix(), payload: payload);
    expect(await publisher.queuedCount(), 1);
    client.close();
    await dir.delete(recursive: true);
  });
}
