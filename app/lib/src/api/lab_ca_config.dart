import 'dart:convert';
import 'dart:io';

/// Lab CA PEM from `--dart-define=TW_LAB_CA_PEM_B64=...` (empty when unset).
String? labCaPemFromDartDefine() {
  const b64 = String.fromEnvironment('TW_LAB_CA_PEM_B64', defaultValue: '');
  if (b64.isEmpty) {
    return null;
  }
  return utf8.decode(base64.decode(b64));
}

/// PEM for extra trusted roots: dart-define, then optional [caCertFilePath] / `TW_CA_FILE`.
String? resolveLabCaPem({String? caCertPem, String? caCertFilePath}) {
  if (caCertPem != null && caCertPem.isNotEmpty) {
    return caCertPem;
  }
  final fromBuild = labCaPemFromDartDefine();
  if (fromBuild != null && fromBuild.isNotEmpty) {
    return fromBuild;
  }
  final path = caCertFilePath ?? Platform.environment['TW_CA_FILE'];
  if (path == null || path.isEmpty) {
    return null;
  }
  try {
    return File(path).readAsStringSync();
  } catch (_) {
    return null;
  }
}

/// PEM passed to the Matrix Rust bridge (same sources as [resolveLabCaPem]).
String? labCaPemForMatrix() => resolveLabCaPem();

SecurityContext? _cachedSecurityContext;
String? _cachedSecurityContextPem;

/// Shared TLS context: system roots plus optional lab CA (never disables verification).
SecurityContext sharedTlsSecurityContext({String? caCertPem, String? caCertFilePath}) {
  final pem = resolveLabCaPem(
    caCertPem: caCertPem,
    caCertFilePath: caCertFilePath,
  );
  if (_cachedSecurityContext != null && _cachedSecurityContextPem == pem) {
    return _cachedSecurityContext!;
  }
  final context = SecurityContext(withTrustedRoots: true);
  if (pem != null && pem.isNotEmpty) {
    context.setTrustedCertificatesBytes(utf8.encode(pem));
  }
  _cachedSecurityContext = context;
  _cachedSecurityContextPem = pem;
  return context;
}

/// Clears cached context (unit tests only).
void resetSharedTlsSecurityContextForTests() {
  _cachedSecurityContext = null;
  _cachedSecurityContextPem = null;
}
