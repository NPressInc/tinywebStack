import 'package:flutter/foundation.dart';

/// Default public base domain for TinyWeb family nodes (`<family>.tinyweb.win`).
const String kDefaultTinyWebBaseDomain = 'tinyweb.win';

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

String _uriToStringWithoutTrailingSlash(Uri uri) {
  final s = uri.toString();
  return s.replaceAll(RegExp(r'/+$'), '');
}

/// Expands bare family slugs (`smith`) to `smith.tinyweb.win` (or [defaultBaseDomain]).
String normalizeFamilyServerInput(
  String raw, {
  String defaultBaseDomain = kDefaultTinyWebBaseDomain,
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return '';
  }

  if (trimmed.contains('://')) {
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.host.isNotEmpty) {
      final hostLower = uri.host.toLowerCase();
      if (!uri.host.contains('.') && hostLower != 'localhost') {
        final expanded = Uri(
          scheme: uri.scheme,
          userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
          host: '$hostLower.$defaultBaseDomain',
          port: uri.hasPort ? uri.port : null,
          path: uri.path.isEmpty ? null : uri.path,
          query: uri.query.isEmpty ? null : uri.query,
          fragment: uri.fragment.isEmpty ? null : uri.fragment,
        );
        return _uriToStringWithoutTrailingSlash(expanded);
      }
    }
    return trimmed;
  }

  var withoutTrailingSlashes = trimmed.replaceAll(RegExp(r'/+$'), '');
  final slashIdx = withoutTrailingSlashes.indexOf('/');
  final hostAndPort = slashIdx >= 0
      ? withoutTrailingSlashes.substring(0, slashIdx)
      : withoutTrailingSlashes;
  final pathSuffix = slashIdx >= 0 ? withoutTrailingSlashes.substring(slashIdx) : '';

  final colonIdx = hostAndPort.indexOf(':');
  final hostPart = colonIdx >= 0 ? hostAndPort.substring(0, colonIdx) : hostAndPort;
  final portSuffix = colonIdx >= 0 ? hostAndPort.substring(colonIdx) : '';

  if (hostPart.isNotEmpty &&
      !hostPart.contains('.') &&
      hostPart.toLowerCase() != 'localhost') {
    return '${hostPart.toLowerCase()}.$defaultBaseDomain$portSuffix$pathSuffix';
  }

  return withoutTrailingSlashes;
}

/// Normalises user input (`smith`, `family.example`, or `https://family.example`) to an origin.
String? normalizeServerOrigin(
  String input, {
  bool allowInsecureLocalhost = kDebugMode,
  String defaultBaseDomain = kDefaultTinyWebBaseDomain,
}) {
  final normalized = normalizeFamilyServerInput(
    input,
    defaultBaseDomain: defaultBaseDomain,
  );
  if (normalized.isEmpty) {
    return null;
  }

  String candidate = normalized;
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

/// Expands bare Matrix server names in MXIDs (`@user:smith` → `@user:smith.tinyweb.win`).
String normalizeEnteredMxid(
  String raw, {
  String defaultBaseDomain = kDefaultTinyWebBaseDomain,
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return '';
  }

  final withAt = trimmed.startsWith('@') ? trimmed : '@$trimmed';
  if (!withAt.contains(':')) {
    return withAt;
  }

  final colonIdx = withAt.indexOf(':');
  final localpart = withAt.substring(0, colonIdx);
  final domainPart = withAt.substring(colonIdx + 1);

  final portColonIdx = domainPart.indexOf(':');
  final host = portColonIdx >= 0 ? domainPart.substring(0, portColonIdx) : domainPart;
  final portSuffix = portColonIdx >= 0 ? domainPart.substring(portColonIdx) : '';

  if (host.isNotEmpty &&
      !host.contains('.') &&
      host.toLowerCase() != 'localhost') {
    return '$localpart:${host.toLowerCase()}.$defaultBaseDomain$portSuffix';
  }

  return '$localpart:$domainPart';
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
