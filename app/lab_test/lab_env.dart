import 'dart:io';

import 'package:tinyweb/src/api/lab_ca_config.dart';
import 'package:tinyweb/src/api/tls_http_client.dart';

String? _resolveIp;
String? _labHostSuffix;

/// Whether [host] should connect via [TW_RESOLVE_IP] (from [TW_HS] host suffix).
bool labHostUsesResolveOverride(String host) {
  final suffix = _labHostSuffix;
  if (suffix == null || suffix.isEmpty) {
    return false;
  }
  return host == suffix || host.endsWith('.$suffix');
}

void _applyLabConnectionFactory(HttpClient client, SecurityContext? ctx) {
  final ip = _resolveIp;
  if (ip == null || ip.isEmpty) {
    return;
  }
  client.connectionFactory = (Uri url, String? proxyHost, int? proxyPort) async {
    if (!labHostUsesResolveOverride(url.host)) {
      return url.scheme == 'https'
          ? SecureSocket.startConnect(url.host, url.port, context: ctx)
          : Socket.startConnect(url.host, url.port);
    }
    final port = url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80);
    final task = await Socket.startConnect(ip, port);
    if (url.scheme != 'https') return task;
    // Connect TCP to the lab IP, then TLS with the real hostname for SNI + verification.
    final secured = task.socket.then(
      (s) => SecureSocket.secure(s, host: url.host, context: ctx),
    );
    return ConnectionTask.fromSocket(secured, task.cancel);
  };
}

/// When `TW_RESOLVE_IP` is set, installs [HttpOverrides] and registers the TLS
/// HTTP client factory so lab hosts (under the [TW_HS] hostname) connect to that
/// IP while preserving URL host, SNI, and verification against [TW_CA_FILE].
///
/// No-op when `TW_RESOLVE_IP` is unset. Call at the start of every `lab_test/`
/// `main()` (safe for skipped tests).
void installLabTestHttpOverrides() {
  final resolveIp = Platform.environment['TW_RESOLVE_IP'];
  if (resolveIp == null || resolveIp.isEmpty) {
    return;
  }
  _resolveIp = resolveIp;

  final hs = Platform.environment['TW_HS'];
  if (hs != null && hs.isNotEmpty) {
    _labHostSuffix = Uri.parse(hs).host;
  }

  HttpOverrides.global = _LabHttpOverrides();

  // HttpClient() already routes through the global override above.
  registerLabHttpClientFactory((SecurityContext context) => HttpClient(context: context));
}

class _LabHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final ctx = context ?? sharedTlsSecurityContext();
    final client = super.createHttpClient(ctx);
    _applyLabConnectionFactory(client, ctx);
    return client;
  }
}
