import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/models.dart';

const _storageKey = 'tinyweb_enrollment_v1';
const _matrixPassphraseKey = 'tinyweb_matrix_store_passphrase_v1';
const _matrixRecoveryKeyKey = 'tinyweb_matrix_recovery_key_v1';
const _matrixE2eeSetupKey = 'tinyweb_matrix_e2ee_setup_v1';
const _matrixRecoverySkippedKey = 'tinyweb_matrix_recovery_skipped_v1';
const _locationExplainerKey = 'tinyweb_location_explainer_v1';
const _notificationsEnabledKey = 'tinyweb_notifications_enabled_v1';
const _unifiedPushTopicKey = 'tinyweb_unifiedpush_topic_v1';
const _unifiedPushEndpointKey = 'tinyweb_unifiedpush_endpoint_v1';
const _apnsTokenKey = 'tinyweb_apns_token_v1';
const _matrixPusherKey = 'tinyweb_matrix_pusher_v1';

abstract class CredentialStore {
  Future<EnrollmentBundle?> read();

  Future<void> write(EnrollmentBundle bundle);

  Future<void> clear();

  Future<String?> readMatrixStorePassphrase();

  Future<String> ensureMatrixStorePassphrase();

  Future<String?> readMatrixRecoveryKey();

  Future<void> writeMatrixRecoveryKey(String key);

  Future<bool> isMatrixE2eeSetupComplete();

  Future<void> setMatrixE2eeSetupComplete({bool skipped = false});

  Future<bool> isMatrixRecoverySkipped();

  Future<bool> hasAcknowledgedLocationSharing();

  Future<void> setLocationSharingAcknowledged();

  Future<bool> areNotificationsEnabled();

  Future<void> setNotificationsEnabled(bool enabled);

  Future<String?> readUnifiedPushTopic();

  Future<void> writeUnifiedPushTopic(String topic);

  Future<String?> readUnifiedPushEndpoint();

  Future<void> writeUnifiedPushEndpoint(String endpoint);

  Future<String?> readApnsTokenHex();

  Future<void> writeApnsTokenHex(String token);

  Future<({String appId, String pushkey})?> readMatrixPusherRegistration();

  Future<void> writeMatrixPusherRegistration({
    required String appId,
    required String pushkey,
  });

  Future<void> clearMatrixPusherRegistration();
}

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<EnrollmentBundle?> read() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return EnrollmentBundle.fromStoredJson(json);
  }

  @override
  Future<void> write(EnrollmentBundle bundle) async {
    await _storage.write(key: _storageKey, value: jsonEncode(_toStored(bundle)));
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _storageKey);
    await _storage.delete(key: _matrixPassphraseKey);
    await _storage.delete(key: _matrixRecoveryKeyKey);
    await _storage.delete(key: _matrixE2eeSetupKey);
    await _storage.delete(key: _matrixRecoverySkippedKey);
    await _storage.delete(key: _locationExplainerKey);
    await _storage.delete(key: _notificationsEnabledKey);
    await _storage.delete(key: _unifiedPushTopicKey);
    await _storage.delete(key: _unifiedPushEndpointKey);
    await _storage.delete(key: _apnsTokenKey);
    await _storage.delete(key: _matrixPusherKey);
  }

  @override
  Future<String?> readMatrixStorePassphrase() =>
      _storage.read(key: _matrixPassphraseKey);

  @override
  Future<String> ensureMatrixStorePassphrase() async {
    final existing = await readMatrixStorePassphrase();
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final passphrase = base64Encode(bytes);
    await _storage.write(key: _matrixPassphraseKey, value: passphrase);
    return passphrase;
  }

  @override
  Future<String?> readMatrixRecoveryKey() =>
      _storage.read(key: _matrixRecoveryKeyKey);

  @override
  Future<void> writeMatrixRecoveryKey(String key) =>
      _storage.write(key: _matrixRecoveryKeyKey, value: key);

  @override
  Future<bool> isMatrixE2eeSetupComplete() async {
    final v = await _storage.read(key: _matrixE2eeSetupKey);
    return v == '1';
  }

  @override
  Future<void> setMatrixE2eeSetupComplete({bool skipped = false}) async {
    await _storage.write(key: _matrixE2eeSetupKey, value: '1');
    if (skipped) {
      await _storage.write(key: _matrixRecoverySkippedKey, value: '1');
    } else {
      await _storage.delete(key: _matrixRecoverySkippedKey);
    }
  }

  @override
  Future<bool> isMatrixRecoverySkipped() async {
    final v = await _storage.read(key: _matrixRecoverySkippedKey);
    return v == '1';
  }

  @override
  Future<bool> hasAcknowledgedLocationSharing() async {
    final v = await _storage.read(key: _locationExplainerKey);
    return v == '1';
  }

  @override
  Future<void> setLocationSharingAcknowledged() =>
      _storage.write(key: _locationExplainerKey, value: '1');

  @override
  Future<bool> areNotificationsEnabled() async {
    final v = await _storage.read(key: _notificationsEnabledKey);
    return v != '0';
  }

  @override
  Future<void> setNotificationsEnabled(bool enabled) => _storage.write(
        key: _notificationsEnabledKey,
        value: enabled ? '1' : '0',
      );

  @override
  Future<String?> readUnifiedPushTopic() =>
      _storage.read(key: _unifiedPushTopicKey);

  @override
  Future<void> writeUnifiedPushTopic(String topic) =>
      _storage.write(key: _unifiedPushTopicKey, value: topic);

  @override
  Future<String?> readUnifiedPushEndpoint() =>
      _storage.read(key: _unifiedPushEndpointKey);

  @override
  Future<void> writeUnifiedPushEndpoint(String endpoint) =>
      _storage.write(key: _unifiedPushEndpointKey, value: endpoint);

  @override
  Future<String?> readApnsTokenHex() => _storage.read(key: _apnsTokenKey);

  @override
  Future<void> writeApnsTokenHex(String token) =>
      _storage.write(key: _apnsTokenKey, value: token);

  @override
  Future<({String appId, String pushkey})?> readMatrixPusherRegistration() async {
    final raw = await _storage.read(key: _matrixPusherKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final appId = map['app_id'] as String?;
      final pushkey = map['pushkey'] as String?;
      if (appId == null || pushkey == null) {
        return null;
      }
      return (appId: appId, pushkey: pushkey);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeMatrixPusherRegistration({
    required String appId,
    required String pushkey,
  }) =>
      _storage.write(
        key: _matrixPusherKey,
        value: jsonEncode({'app_id': appId, 'pushkey': pushkey}),
      );

  @override
  Future<void> clearMatrixPusherRegistration() =>
      _storage.delete(key: _matrixPusherKey);

  Map<String, dynamic> _toStored(EnrollmentBundle bundle) =>
      enrollmentToStoredJson(bundle);
}

Map<String, dynamic> enrollmentToStoredJson(EnrollmentBundle bundle) {
    return {
      'device_id': bundle.deviceId,
      'username': bundle.username,
      'role': bundle.role,
      'mxid': bundle.mxid,
      'server_name': bundle.serverName,
      'server_origin': bundle.serverOrigin,
      'dashboard': {
        'token': bundle.dashboardToken,
        'api_base': bundle.apiBase,
      },
      'discovery': {
        'server_name': bundle.discovery.serverName,
        'matrix_server': bundle.discovery.matrixServer,
        'app_api_version': bundle.discovery.appApiVersion,
        'dashboard_base': bundle.discovery.dashboardBase,
        'enroll_url': bundle.discovery.enrollUrl,
        'matrix_homeserver_url': bundle.discovery.matrixHomeserverUrl,
        'caldav_root': bundle.discovery.caldavRoot,
        'events_url': bundle.discovery.eventsUrl,
        'location_url': bundle.discovery.locationUrl,
      },
      if (bundle.rawJson?['matrix'] != null)
        'matrix': bundle.rawJson!['matrix'],
      if (bundle.rawJson?['owntracks'] != null)
        'owntracks': bundle.rawJson!['owntracks'],
      if (bundle.rawJson?['caldav'] != null)
        'caldav': bundle.rawJson!['caldav'],
      if (bundle.rawJson?['mobilizon'] != null)
        'mobilizon': bundle.rawJson!['mobilizon'],
      if (bundle.rawJson?['push'] != null) 'push': bundle.rawJson!['push'],
    };
}

class InMemoryCredentialStore implements CredentialStore {
  Map<String, dynamic>? _json;
  String? _passphrase;
  String? _recoveryKey;
  bool _e2eeSetup = false;
  bool _recoverySkipped = false;

  @override
  Future<EnrollmentBundle?> read() async {
    if (_json == null) {
      return null;
    }
    return EnrollmentBundle.fromStoredJson(_json!);
  }

  @override
  Future<void> write(EnrollmentBundle bundle) async {
    _json = enrollmentToStoredJson(bundle);
  }

  @override
  Future<void> clear() async {
    _json = null;
    _passphrase = null;
    _recoveryKey = null;
    _e2eeSetup = false;
    _recoverySkipped = false;
    _locationAck = false;
    _notificationsEnabled = true;
    _upTopic = null;
    _upEndpoint = null;
    _apnsToken = null;
    _pusher = null;
  }

  @override
  Future<String?> readMatrixStorePassphrase() async => _passphrase;

  @override
  Future<String> ensureMatrixStorePassphrase() async {
    if (_passphrase != null) {
      return _passphrase!;
    }
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    _passphrase = base64Encode(bytes);
    return _passphrase!;
  }

  @override
  Future<String?> readMatrixRecoveryKey() async => _recoveryKey;

  @override
  Future<void> writeMatrixRecoveryKey(String key) async {
    _recoveryKey = key;
  }

  @override
  Future<bool> isMatrixE2eeSetupComplete() async => _e2eeSetup;

  @override
  Future<void> setMatrixE2eeSetupComplete({bool skipped = false}) async {
    _e2eeSetup = true;
    _recoverySkipped = skipped;
  }

  @override
  Future<bool> isMatrixRecoverySkipped() async => _recoverySkipped;

  bool _locationAck = false;
  bool _notificationsEnabled = true;
  String? _upTopic;
  String? _upEndpoint;
  String? _apnsToken;
  ({String appId, String pushkey})? _pusher;

  @override
  Future<bool> hasAcknowledgedLocationSharing() async => _locationAck;

  @override
  Future<void> setLocationSharingAcknowledged() async {
    _locationAck = true;
  }

  @override
  Future<bool> areNotificationsEnabled() async => _notificationsEnabled;

  @override
  Future<void> setNotificationsEnabled(bool enabled) async {
    _notificationsEnabled = enabled;
  }

  @override
  Future<String?> readUnifiedPushTopic() async => _upTopic;

  @override
  Future<void> writeUnifiedPushTopic(String topic) async {
    _upTopic = topic;
  }

  @override
  Future<String?> readUnifiedPushEndpoint() async => _upEndpoint;

  @override
  Future<void> writeUnifiedPushEndpoint(String endpoint) async {
    _upEndpoint = endpoint;
  }

  @override
  Future<String?> readApnsTokenHex() async => _apnsToken;

  @override
  Future<void> writeApnsTokenHex(String token) async {
    _apnsToken = token;
  }

  @override
  Future<({String appId, String pushkey})?> readMatrixPusherRegistration() async =>
      _pusher;

  @override
  Future<void> writeMatrixPusherRegistration({
    required String appId,
    required String pushkey,
  }) async {
    _pusher = (appId: appId, pushkey: pushkey);
  }

  @override
  Future<void> clearMatrixPusherRegistration() async {
    _pusher = null;
  }
}
