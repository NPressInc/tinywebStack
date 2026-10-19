import 'package:battery_plus/battery_plus.dart';

import 'location_fix.dart';

/// OwnTracks battery status (BSD-style): 0 unknown, 1 unplugged, 2 charging, 3 full.
int owntracksBatteryStatus(BatteryState state) {
  switch (state) {
    case BatteryState.charging:
      return 2;
    case BatteryState.full:
      return 3;
    case BatteryState.discharging:
      return 1;
    case BatteryState.connectedNotCharging:
      return 2;
    case BatteryState.unknown:
      return 0;
  }
}

/// Builds OwnTracks Recorder HTTP publish JSON for `_type: location`.
Map<String, dynamic> buildOwntracksLocationPayload({
  required LocationFix fix,
  required String tid,
  required int batteryLevel,
  required BatteryState batteryState,
  String connection = 'w',
  String trigger = 'p',
}) {
  final body = <String, dynamic>{
    '_type': 'location',
    'lat': fix.latitude,
    'lon': fix.longitude,
    'tst': fix.epochSeconds,
    'tid': tid,
    'conn': connection,
    't': trigger,
    'batt': batteryLevel.clamp(0, 100),
    'bs': owntracksBatteryStatus(batteryState).clamp(0, 3),
  };
  if (fix.accuracyMeters != null && fix.accuracyMeters! >= 0) {
    body['acc'] = fix.accuracyMeters;
  }
  if (fix.altitudeMeters != null) {
    body['alt'] = fix.altitudeMeters;
  }
  if (fix.speedMetersPerSecond != null && fix.speedMetersPerSecond! >= 0) {
    body['vel'] = fix.speedMetersPerSecond;
  }
  if (fix.headingDegrees != null && fix.headingDegrees! >= 0) {
    body['cog'] = fix.headingDegrees;
  }
  return body;
}
