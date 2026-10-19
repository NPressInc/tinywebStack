import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'location_fix.dart';

/// iOS significant-change + circular region updates via native CLLocationManager.
class IosLocationBridge {
  IosLocationBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _method = methodChannel ?? const MethodChannel('tinyweb/location_ios'),
        _events = eventChannel ?? const EventChannel('tinyweb/location_ios/events');

  final MethodChannel _method;
  final EventChannel _events;

  Stream<LocationFix>? _stream;

  Stream<LocationFix> get onLocation {
    _stream ??= _events.receiveBroadcastStream().map((event) {
      final map = Map<String, dynamic>.from(event as Map);
      final tst = map['tst'];
      final ts = tst is int
          ? DateTime.fromMillisecondsSinceEpoch(tst * 1000)
          : DateTime.now();
      return LocationFix(
        latitude: (map['lat'] as num).toDouble(),
        longitude: (map['lon'] as num).toDouble(),
        timestamp: ts,
        accuracyMeters: map['acc'] is num ? (map['acc'] as num).toDouble() : null,
        altitudeMeters: map['alt'] is num ? (map['alt'] as num).toDouble() : null,
        speedMetersPerSecond: map['vel'] is num ? (map['vel'] as num).toDouble() : null,
        headingDegrees: map['cog'] is num ? (map['cog'] as num).toDouble() : null,
      );
    });
    return _stream!;
  }

  Future<void> start() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      await _method.invokeMethod<void>('start');
    }
  }

  Future<void> stop() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      await _method.invokeMethod<void>('stop');
    }
  }
}
