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

  @override
  Future<bool> hasAcknowledgedLocationSharing() async => _locationAck;

  @override
  Future<void> setLocationSharingAcknowledged() async {
    _locationAck = true;
  }
}
