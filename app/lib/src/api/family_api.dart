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
      final json = jsonDecode(response.body) as Map<String, dynamic>;
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
      final json = jsonDecode(response.body);
      final list = json is List
          ? json
          : (json as Map<String, dynamic>)['members'] as List<dynamic>? ?? [];
      return list
          .map((e) => FamilyMember.fromJson(e as Map<String, dynamic>))
          .toList();
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
      final json = jsonDecode(response.body) as Map<String, dynamic>;
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

  Never _throwForStatus(http.Response response) {
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
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
