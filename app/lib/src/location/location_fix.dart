/// Platform-neutral position snapshot for OwnTracks publish and tests.
class LocationFix {
  LocationFix({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracyMeters,
    this.altitudeMeters,
    this.speedMetersPerSecond,
    this.headingDegrees,
  });

  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double? accuracyMeters;
  final double? altitudeMeters;
  final double? speedMetersPerSecond;
  final double? headingDegrees;

  int get epochSeconds => timestamp.millisecondsSinceEpoch ~/ 1000;
}
