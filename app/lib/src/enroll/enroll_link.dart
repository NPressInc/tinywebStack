import 'package:flutter/foundation.dart';

/// Parsed enrollment payload from a QR code, deep link, or manual entry.
class EnrollLinkData {
  EnrollLinkData({
    this.serverHost,
    this.code,
    this.serverOrigin,
  });

  final String? serverHost;
  final String? code;
  final String? serverOrigin;
}

/// Rejects non-HTTPS origins unless [allowInsecureLocalhost] (debug + localhost / emulator).
bool isAllowedServerOrigin(String origin, {bool allowInsecureLocalhost = false}) {
  final uri = Uri.tryParse(origin);
  if (uri == null || uri.host.isEmpty) {
    return false;
  }
  if (uri.scheme == 'https') {
    return true;
  }
  if (!allowInsecureLocalhost || uri.scheme != 'http') {
    return false;
  }
  final host = uri.host.toLowerCase();
  return host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '10.0.2.2';
}

/// Normalises user input (`family.example` or `https://family.example`) to an origin.
String? normalizeServerOrigin(
  String input, {
  bool allowInsecureLocalhost = kDebugMode,
}) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  String candidate = trimmed;
  if (!candidate.contains('://')) {
    candidate = 'https://$candidate';
  }

  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.host.isEmpty) {
    return null;
  }

  final origin = Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  ).toString().replaceAll(RegExp(r'/+$'), '');

  if (!isAllowedServerOrigin(origin, allowInsecureLocalhost: allowInsecureLocalhost)) {
    return null;
  }
  return origin;
}

/// Parses `tinyweb://enroll?...`, bare codes, or full HTTPS URLs with code query params.
EnrollLinkData parseEnrollLink(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return EnrollLinkData();
  }

  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.scheme == 'tinyweb' && uri.host == 'enroll') {
    final server = uri.queryParameters['server'];
    final code = uri.queryParameters['code'];
    final origin = server != null ? normalizeServerOrigin(server) : null;
    return EnrollLinkData(
      serverHost: server,
      code: code,
      serverOrigin: origin,
    );
  }

  if (uri != null &&
      (uri.scheme == 'https' ||
          (kDebugMode &&
              uri.scheme == 'http' &&
              isAllowedServerOrigin(uri.origin, allowInsecureLocalhost: true)))) {
    final code = uri.queryParameters['code'];
    if (code != null && code.isNotEmpty) {
      final origin = Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      ).toString();
      return EnrollLinkData(
        serverHost: uri.host,
        code: code,
        serverOrigin: normalizeServerOrigin(origin),
      );
    }
  }

  if (!trimmed.contains('://') && !trimmed.contains('/')) {
    return EnrollLinkData(code: trimmed);
  }

  return EnrollLinkData();
}
