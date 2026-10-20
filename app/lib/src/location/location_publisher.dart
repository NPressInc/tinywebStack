import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/tls_http_client.dart';
import 'package:path_provider/path_provider.dart';

import '../api/models.dart';
import 'location_fix.dart';

const locationCredentialsRejectedMessage =
    'location credentials rejected — ask a parent to re-enroll this phone';

const _maxQueueEntries = 500;
const _maxQueueAge = Duration(days: 7);
const _throttleInterval = Duration(seconds: 60);
const _throttleDistanceMeters = 100.0;

class LocationPublisher {
  LocationPublisher({
    required this._credentials,
    http.Client? httpClient,
    Future<Directory> Function()? queueDirectory,
    DateTime Function()? clock,
  })  : _client = httpClient ?? defaultTlsHttpClient(),
        _queueDirectory = queueDirectory ?? _defaultQueueDir,
        _clock = clock ?? DateTime.now;

  final OwnTracksCredentials _credentials;
  final http.Client _client;
  final Future<Directory> Function() _queueDirectory;
  final DateTime Function() _clock;

  DateTime? _lastPublishAt;
  double? _lastPublishLat;
  double? _lastPublishLon;
  Duration _backoff = const Duration(seconds: 5);
  bool _credentialsRejected = false;
  bool _flushing = false;

  bool get credentialsRejected => _credentialsRejected;
  String? get errorMessage =>
      _credentialsRejected ? locationCredentialsRejectedMessage : null;
  DateTime? get lastSuccessfulPublishAt => _lastPublishAt;

  static Future<Directory> _defaultQueueDir() async {
    final dir = await getApplicationSupportDirectory();
    final sub = Directory('${dir.path}/location');
    if (!await sub.exists()) {
      await sub.create(recursive: true);
    }
    return sub;
  }

  Future<File> _queueFile() async {
    final dir = await _queueDirectory();
    return File('${dir.path}/publish_queue.json');
  }

  Future<void> publish(LocationFix fix, {required Map<String, dynamic> payload}) async {
    if (_credentialsRejected) {
      return;
    }
    if (!_shouldPublishNow(fix)) {
      return;
    }
    final result = await _postPayload(payload);
    if (result == _PostResult.success) {
      _markPublished(fix);
      _backoff = const Duration(seconds: 5);
      await _flushQueue();
      return;
    }
    if (result == _PostResult.unauthorized) {
      _credentialsRejected = true;
      return;
    }
    await _enqueue(payload);
    unawaited(_scheduleFlush());
  }

  /// Test hook: POST without throttle (still updates queue on failure).
  Future<LocationPostResult> postPayloadForTest(Map<String, dynamic> payload) async {
    final result = await _postPayload(payload);
    switch (result) {
      case _PostResult.success:
        return LocationPostResult.success;
      case _PostResult.unauthorized:
        return LocationPostResult.unauthorized;
      case _PostResult.retryable:
        return LocationPostResult.retryable;
    }
  }

  Future<void> flushQueueNow() => _flushQueue();

  bool _shouldPublishNow(LocationFix fix) {
    if (_lastPublishAt == null || _lastPublishLat == null || _lastPublishLon == null) {
      return true;
    }
    final elapsed = _clock().difference(_lastPublishAt!);
    if (elapsed >= _throttleInterval) {
      return true;
    }
    return _distanceMeters(_lastPublishLat!, _lastPublishLon!, fix.latitude, fix.longitude) >
        _throttleDistanceMeters;
  }

  void _markPublished(LocationFix fix) {
    _lastPublishAt = _clock();
    _lastPublishLat = fix.latitude;
    _lastPublishLon = fix.longitude;
    _persistState();
  }

  Future<void> _scheduleFlush() async {
    if (_flushing || _credentialsRejected) {
      return;
    }
    _flushing = true;
    try {
      await Future<void>.delayed(_backoff);
      await _flushQueue();
      _backoff = Duration(seconds: min(_backoff.inSeconds * 2, 300));
    } finally {
      _flushing = false;
    }
  }

  Future<void> _flushQueue() async {
    if (_credentialsRejected) {
      return;
    }
    final data = await _readQueueFile();
    final queue = List<Map<String, dynamic>>.from(data['queue'] as List? ?? []);
    while (queue.isNotEmpty && !_credentialsRejected) {
      final entry = queue.first;
      final payload = Map<String, dynamic>.from(entry['payload'] as Map);
      final result = await _postPayload(payload);
      if (result == _PostResult.success) {
        queue.removeAt(0);
        final tst = payload['tst'];
        if (tst is int) {
          _lastPublishAt = DateTime.fromMillisecondsSinceEpoch(tst * 1000);
        }
        if (payload['lat'] is num && payload['lon'] is num) {
          _lastPublishLat = (payload['lat'] as num).toDouble();
          _lastPublishLon = (payload['lon'] as num).toDouble();
        }
        await _writeQueueFile(queue);
        continue;
      }
      if (result == _PostResult.unauthorized) {
        _credentialsRejected = true;
        return;
      }
      break;
    }
    await _writeQueueFile(queue);
  }

  Future<_PostResult> _postPayload(Map<String, dynamic> payload) async {
    final uri = Uri.parse(_credentials.url);
    final auth =
        base64Encode(utf8.encode('${_credentials.username}:${_credentials.password}'));
    try {
      final response = await _client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Basic $auth',
          'X-Limit-U': _credentials.username,
          'X-Limit-D': _credentials.device,
        },
        body: jsonEncode(payload),
      );
      if (response.statusCode == 200) {
        return _PostResult.success;
      }
      if (response.statusCode == 401) {
        return _PostResult.unauthorized;
      }
      return _PostResult.retryable;
    } on SocketException {
      return _PostResult.retryable;
    } on HttpException {
      return _PostResult.retryable;
    } on IOException {
      return _PostResult.retryable;
    }
  }

  Future<void> _enqueue(Map<String, dynamic> payload) async {
    final data = await _readQueueFile();
    var queue = List<Map<String, dynamic>>.from(data['queue'] as List? ?? []);
    final now = _clock();
    queue.add({
      'payload': payload,
      'enqueued_at': now.toUtc().toIso8601String(),
    });
    queue = _pruneQueue(queue, now);
    await _writeQueueFile(queue);
  }

  List<Map<String, dynamic>> _pruneQueue(
    List<Map<String, dynamic>> queue,
    DateTime now,
  ) {
    final cutoff = now.subtract(_maxQueueAge);
    queue = queue.where((e) {
      final at = DateTime.tryParse(e['enqueued_at'] as String? ?? '');
      if (at == null) {
        return false;
      }
      return !at.isBefore(cutoff);
    }).toList();
    while (queue.length > _maxQueueEntries) {
      queue.removeAt(0);
    }
    return queue;
  }

  Future<Map<String, dynamic>> _readQueueFile() async {
    final file = await _queueFile();
    if (!await file.exists()) {
      return {'queue': <Map<String, dynamic>>[]};
    }
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final queue = json['queue'];
      if (queue is List) {
        return {
          'queue': queue
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList(),
        };
      }
    } catch (_) {}
    return {'queue': <Map<String, dynamic>>[]};
  }

  Future<void> _writeQueueFile(List<Map<String, dynamic>> queue) async {
    final file = await _queueFile();
    final body = jsonEncode({
      'queue': queue,
      if (_lastPublishAt != null) 'last_publish_at': _lastPublishAt!.toUtc().toIso8601String(),
      if (_lastPublishLat != null) 'last_lat': _lastPublishLat,
      if (_lastPublishLon != null) 'last_lon': _lastPublishLon,
    });
    await file.writeAsString(body);
  }

  Future<void> _persistState() async {
    final data = await _readQueueFile();
    final queue = List<Map<String, dynamic>>.from(data['queue'] as List? ?? []);
    await _writeQueueFile(queue);
  }

  Future<int> queuedCount() async {
    final data = await _readQueueFile();
    return (data['queue'] as List? ?? []).length;
  }

  Future<void> loadPersistedState() async {
    final file = await _queueFile();
    if (!await file.exists()) {
      return;
    }
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final at = json['last_publish_at'] as String?;
      if (at != null) {
        _lastPublishAt = DateTime.tryParse(at);
      }
      if (json['last_lat'] is num) {
        _lastPublishLat = (json['last_lat'] as num).toDouble();
      }
      if (json['last_lon'] is num) {
        _lastPublishLon = (json['last_lon'] as num).toDouble();
      }
    } catch (_) {}
  }

  void close() {
    _client.close();
  }
}

enum LocationPostResult { success, unauthorized, retryable }

enum _PostResult { success, unauthorized, retryable }

double _distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * pi / 180;
  final p2 = lat2 * pi / 180;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLon = (lon2 - lon1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(p1) * cos(p2) * sin(dLon / 2) * sin(dLon / 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return r * c;
}
