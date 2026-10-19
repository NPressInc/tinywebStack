import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

String enrollPlatformLabel() {
  if (kIsWeb) {
    return 'other';
  }
  if (Platform.isAndroid) {
    return 'android';
  }
  if (Platform.isIOS) {
    return 'ios';
  }
  return 'other';
}

class FamilyApiClient {
  FamilyApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<EnrollmentBundle> enroll({
    required FamilyDiscovery discovery,
    required String method,
    String? username,
    String? password,
    String? code,
    String deviceName = 'TinyWeb',
  }) async {
    if (!discovery.hasEnrollUrl) {
      throw EnrollException(
        EnrollErrorKind.needsUpdate,
        'This TinyWeb box needs an update',
      );
    }

    final body = <String, dynamic>{
      'method': method,
      'device_name': deviceName,
      'platform': enrollPlatformLabel(),
    };
    if (method == 'password') {
      body['username'] = username;
      body['password'] = password;
    } else if (method == 'code') {
      body['code'] = code;
    }

    final response = await _client.post(
      Uri.parse(discovery.resolveEnrollEndpoint()),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      final json = _jsonMapFromResponse(response);
      return EnrollmentBundle.fromJson(json, discovery.serverOrigin, discovery);
    }

    _throwForStatus(response);
  }

  Future<List<FamilyMember>> fetchMembers(EnrollmentBundle bundle) async {
    final base = bundle.serverOrigin.endsWith('/')
        ? bundle.serverOrigin.substring(0, bundle.serverOrigin.length - 1)
        : bundle.serverOrigin;
    final path = bundle.apiBase.startsWith('/')
        ? bundle.apiBase
        : '/${bundle.apiBase}';
    final url = '$base$path/members';
    final response = await _client.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer ${bundle.dashboardToken}'},
    );
    if (response.statusCode == 200) {
      final json = _jsonFromResponse(response);
      final list = json is List
          ? json
          : (json as Map<String, dynamic>)['members'] as List<dynamic>? ?? [];
      return list
          .map((e) => FamilyMember.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    _throwForStatus(response);
  }

  Future<LocationsResponse> fetchLocations(EnrollmentBundle bundle) async {
    final url = _apiUrl(bundle, '/locations');
    final response = await _client.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer ${bundle.dashboardToken}'},
    );
    if (response.statusCode == 200) {
      final json = _jsonMapFromResponse(response);
      return LocationsResponse.fromJson(json);
    }
    _throwForStatus(response);
  }

  Future<KidTrackResponse> fetchKidTrack(
    EnrollmentBundle bundle,
    String username, {
    int hours = 24,
  }) async {
    final path = '/locations/${Uri.encodeComponent(username)}/track?hours=$hours';
    final url = _apiUrl(bundle, path);
    final response = await _client.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer ${bundle.dashboardToken}'},
    );
    if (response.statusCode == 200) {
      final json = _jsonMapFromResponse(response);
      return KidTrackResponse.fromJson(json);
    }
    _throwForStatus(response);
  }

  String _apiUrl(EnrollmentBundle bundle, String suffix) {
    final base = bundle.serverOrigin.endsWith('/')
        ? bundle.serverOrigin.substring(0, bundle.serverOrigin.length - 1)
        : bundle.serverOrigin;
    final path = bundle.apiBase.startsWith('/')
        ? bundle.apiBase
        : '/${bundle.apiBase}';
    final tail = suffix.startsWith('/') ? suffix : '/$suffix';
    return '$base$path$tail';
  }

  Future<KidPermissions> fetchKidPermissions(
    EnrollmentBundle bundle,
    String username,
  ) async {
    final url = _apiUrl(
      bundle,
      '/permissions/${Uri.encodeComponent(username)}',
    );
    final response = await _client.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer ${bundle.dashboardToken}'},
    );
    if (response.statusCode == 200) {
      final json = _jsonMapFromResponse(response);
      return KidPermissions.fromJson(json);
    }
    _throwForStatus(response);
  }

  Future<KidPermissions> updateKidPermissions(
    EnrollmentBundle bundle,
    String username,
    Map<String, dynamic> body,
  ) async {
    final url = _apiUrl(
      bundle,
      '/permissions/${Uri.encodeComponent(username)}',
    );
    final response = await _client.put(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer ${bundle.dashboardToken}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
    if (response.statusCode == 200) {
      final json = _jsonMapFromResponse(response);
      return KidPermissions.fromJson(json);
    }
    _throwForStatus(response);
  }

  Future<FederationPeersResponse> fetchFederationPeers(
    EnrollmentBundle bundle,
  ) async {
    final url = _apiUrl(bundle, '/federation');
    final response = await _client.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer ${bundle.dashboardToken}'},
    );
    if (response.statusCode == 200) {
      final json = _jsonMapFromResponse(response);
      return FederationPeersResponse.fromJson(json);
    }
    _throwForStatus(response);
  }

  Future<AppMeProfile> fetchMe(EnrollmentBundle bundle) async {
    final url = bundle.meUrl(bundle.serverOrigin);
    final response = await _client.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer ${bundle.dashboardToken}'},
    );

    if (response.statusCode == 200) {
      final json = _jsonMapFromResponse(response);
      return AppMeProfile.fromJson(json);
    }
    if (response.statusCode == 401) {
      throw EnrollException(
        EnrollErrorKind.invalidCredentials,
        'This device was removed from your family. Please enroll again.',
      );
    }
    _throwForStatus(response);
  }

  dynamic _jsonFromResponse(http.Response response) {
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw EnrollException(
        EnrollErrorKind.server,
        'Family server returned a non-JSON response',
      );
    }
  }

  Map<String, dynamic> _jsonMapFromResponse(http.Response response) {
    final decoded = _jsonFromResponse(response);
    if (decoded is! Map<String, dynamic>) {
      throw EnrollException(
        EnrollErrorKind.server,
        'Family server returned an unexpected response',
      );
    }
    return decoded;
  }

  Never _throwForStatus(http.Response response) {
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        json = decoded;
      }
    } catch (_) {}

    if (response.statusCode == 401) {
      throw EnrollException(EnrollErrorKind.invalidCredentials);
    }
    if (response.statusCode == 403) {
      throw EnrollException(EnrollErrorKind.notFamilyMember);
    }
    if (response.statusCode == 429) {
      throw EnrollException(EnrollErrorKind.rateLimited);
    }
    final err = json?['error'] as String?;
    throw EnrollException(
      EnrollErrorKind.server,
      err ?? 'Request failed (${response.statusCode})',
    );
  }

  void close() {
    _client.close();
  }
}
