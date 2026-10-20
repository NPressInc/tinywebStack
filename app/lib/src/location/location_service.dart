import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../api/models.dart';
import '../api/tls_http_client.dart';
import 'ios_location_bridge.dart';
import 'location_fix.dart';
import 'location_publisher.dart';
import 'owntracks_payload.dart';

enum LocationSharingStatus {
  stopped,
  starting,
  running,
  permissionDenied,
  permissionPermanentlyDenied,
  error,
}

class LocationService extends ChangeNotifier {
  LocationService({
    this._credentials,
    this._httpClient,
    this._publisher,
    IosLocationBridge? iosBridge,
    Battery? battery,
  })  : _iosBridge = iosBridge ?? IosLocationBridge(),
        _battery = battery ?? Battery();

  OwnTracksCredentials? _credentials;
  final http.Client? _httpClient;
  LocationPublisher? _publisher;
  final IosLocationBridge _iosBridge;
  final Battery _battery;

  LocationSharingStatus status = LocationSharingStatus.stopped;
  String? statusDetail;
  DateTime? lastSentAt;
  StreamSubscription<Position>? _androidSub;
  StreamSubscription<LocationFix>? _iosSub;

  bool get isRunning => status == LocationSharingStatus.running;

  void updateCredentials(OwnTracksCredentials? credentials) {
    _credentials = credentials;
    _publisher?.close();
    _publisher = null;
  }

  Future<LocationPermissionState> requestPermissions() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      return LocationPermissionState.denied;
    }
    if (permission == LocationPermission.deniedForever) {
      return LocationPermissionState.deniedForever;
    }
    if (permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
      if (permission != LocationPermission.always) {
        permission = await Geolocator.requestPermission();
      }
    }
    if (permission != LocationPermission.always) {
      return LocationPermissionState.needsAlways;
    }
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }
    return LocationPermissionState.granted;
  }

  Future<void> start() async {
    final creds = _credentials;
    if (creds == null || !creds.shouldPublish) {
      return;
    }
    status = LocationSharingStatus.starting;
    statusDetail = null;
    notifyListeners();

    final perm = await requestPermissions();
    if (perm == LocationPermissionState.denied) {
      status = LocationSharingStatus.permissionDenied;
      notifyListeners();
      return;
    }
    if (perm == LocationPermissionState.deniedForever) {
      status = LocationSharingStatus.permissionPermanentlyDenied;
      notifyListeners();
      return;
    }
    if (perm == LocationPermissionState.needsAlways) {
      status = LocationSharingStatus.permissionDenied;
      statusDetail =
          'Allow location "All the time" so sharing works in the background.';
      notifyListeners();
      return;
    }

    _publisher ??= LocationPublisher(
      credentials: creds,
      httpClient: _httpClient ?? defaultTlsHttpClient(),
    );
    await _publisher!.loadPersistedState();

    if (_publisher!.credentialsRejected) {
      status = LocationSharingStatus.error;
      statusDetail = locationCredentialsRejectedMessage;
      notifyListeners();
      return;
    }

    await _startPlatformStream();
    status = LocationSharingStatus.running;
    notifyListeners();
  }

  Future<void> stop() async {
    await _androidSub?.cancel();
    _androidSub = null;
    await _iosSub?.cancel();
    _iosSub = null;
    await _iosBridge.stop();
    status = LocationSharingStatus.stopped;
    notifyListeners();
  }

  Future<void> _startPlatformStream() async {
    if (!kIsWeb && Platform.isIOS) {
      await _iosBridge.start();
      _iosSub = _iosBridge.onLocation.listen(_onFix);
      return;
    }
    if (!kIsWeb && Platform.isAndroid) {
      final stream = Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 50,
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'TinyWeb',
            notificationText:
                'TinyWeb is sharing your location with your family',
            notificationChannelName: 'Location sharing',
          ),
        ),
      );
      _androidSub = stream.listen(_onPosition);
    }
  }

  Future<void> _onPosition(Position position) async {
    await _onFix(
      LocationFix(
        latitude: position.latitude,
        longitude: position.longitude,
        timestamp: position.timestamp,
        accuracyMeters: position.accuracy,
        altitudeMeters: position.altitude,
        speedMetersPerSecond: position.speed,
        headingDegrees: position.heading,
      ),
    );
  }

  Future<void> _onFix(LocationFix fix) async {
    final publisher = _publisher;
    final creds = _credentials;
    if (publisher == null || creds == null) {
      return;
    }
    final level = await _battery.batteryLevel;
    final state = await _battery.batteryState;
    final payload = buildOwntracksLocationPayload(
      fix: fix,
      tid: creds.tid,
      batteryLevel: level,
      batteryState: state,
      connection: 'w',
      trigger: 'p',
    );
    await publisher.publish(fix, payload: payload);
    if (publisher.credentialsRejected) {
      status = LocationSharingStatus.error;
      statusDetail = locationCredentialsRejectedMessage;
      await stop();
      notifyListeners();
      return;
    }
    if (publisher.lastSuccessfulPublishAt != null) {
      lastSentAt = publisher.lastSuccessfulPublishAt;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(stop());
    _publisher?.close();
    super.dispose();
  }
}

enum LocationPermissionState {
  granted,
  denied,
  deniedForever,
  needsAlways,
}
