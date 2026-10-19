import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/models.dart';

const _storageKey = 'tinyweb_enrollment_v1';

abstract class CredentialStore {
  Future<EnrollmentBundle?> read();

  Future<void> write(EnrollmentBundle bundle);

  Future<void> clear();
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
  }

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
    };
}

class InMemoryCredentialStore implements CredentialStore {
  Map<String, dynamic>? _json;

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
  }
}
