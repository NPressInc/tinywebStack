import 'dart:convert';

import 'package:http/http.dart' as http;

import 'tls_http_client.dart';

import 'models.dart';

export '../enroll/enroll_link.dart'
    show kDefaultTinyWebBaseDomain, normalizeEnteredMxid, normalizeFamilyServerInput;

class DiscoveryClient {
  DiscoveryClient({http.Client? client})
      : _client = client ?? defaultTlsHttpClient(),
        _ownsClient = client != null;

  final http.Client _client;
  final bool _ownsClient;

  static String wellKnownUrl(String serverOrigin) {
    final base = serverOrigin.endsWith('/')
        ? serverOrigin.substring(0, serverOrigin.length - 1)
        : serverOrigin;
    return '$base/.well-known/tinywebstack-family.json';
  }

  Future<FamilyDiscovery> fetch(String serverOrigin) async {
    final response = await _client.get(Uri.parse(wellKnownUrl(serverOrigin)));
    if (response.statusCode != 200) {
      throw EnrollException(
        EnrollErrorKind.server,
        'Could not reach your TinyWeb box (${response.statusCode})',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return FamilyDiscovery.fromJson(json, serverOrigin);
  }

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}
