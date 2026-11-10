import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../enroll/enroll_link.dart';
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
    final host = hostOf(serverOrigin);
    final http.Response response;
    try {
      response = await _client
          .get(Uri.parse(wellKnownUrl(serverOrigin)))
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw EnrollException(
        EnrollErrorKind.network,
        unreachableBoxMessage(host.isEmpty ? serverOrigin : host),
      );
    } on SocketException {
      throw EnrollException(
        EnrollErrorKind.network,
        unreachableBoxMessage(host.isEmpty ? serverOrigin : host),
      );
    } on http.ClientException {
      throw EnrollException(
        EnrollErrorKind.network,
        unreachableBoxMessage(host.isEmpty ? serverOrigin : host),
      );
    } on TlsException {
      throw EnrollException(
        EnrollErrorKind.network,
        unreachableBoxMessage(host.isEmpty ? serverOrigin : host),
      );
    }
    if (response.statusCode != 200) {
      throw EnrollException(
        EnrollErrorKind.server,
        "That address isn't a TinyWeb family server. Check the family name.",
      );
    }
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('not an object');
      }
      json = decoded;
    } on FormatException {
      throw EnrollException(
        EnrollErrorKind.server,
        "That address isn't a TinyWeb family server. Check the family name.",
      );
    }
    final discovery = FamilyDiscovery.fromJson(json, serverOrigin);
    final named = discovery.serverName;
    if (named != null &&
        named.isNotEmpty &&
        !familyHostsMatch(serverOrigin, named)) {
      throw EnrollException(
        EnrollErrorKind.wrongServer,
        wrongServerMessage(
          askedFor: host.isEmpty ? serverOrigin : host,
          reached: named,
        ),
      );
    }
    return discovery;
  }

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}
