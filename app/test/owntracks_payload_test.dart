import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/location/location_fix.dart';
import 'package:tinyweb/src/location/owntracks_payload.dart';

void main() {
  test('builds OwnTracks location JSON', () {
    final fix = LocationFix(
      latitude: 40.01,
      longitude: -105.02,
      timestamp: DateTime.utc(2026, 1, 2, 3, 4, 5),
      accuracyMeters: 12,
      altitudeMeters: 1600,
      speedMetersPerSecond: 1.5,
      headingDegrees: 90,
    );
    final json = buildOwntracksLocationPayload(
      fix: fix,
      tid: 'ab',
      batteryLevel: 77,
      batteryState: BatteryState.charging,
    );
    expect(json['_type'], 'location');
    expect(json['lat'], 40.01);
    expect(json['lon'], -105.02);
    expect(json['tst'], fix.epochSeconds);
    expect(json['tid'], 'ab');
    expect(json['batt'], 77);
    expect(json['bs'], 2);
    expect(json['conn'], 'w');
    expect(json['t'], 'p');
    expect(json['acc'], 12);
  });
}
