import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'lab_ca_config.dart';

/// Optional hook for `lab_test/lab_env.dart` when `TW_RESOLVE_IP` is set.
HttpClient Function(SecurityContext context)? _labHttpClientFactory;

void registerLabHttpClientFactory(
  HttpClient Function(SecurityContext context)? factory,
) {
  _labHttpClientFactory = factory;
}

/// HTTP client that uses [sharedTlsSecurityContext] (system roots + optional lab CA).
http.Client createTlsHttpClient({
  String? caCertPem,
  String? caCertFilePath,
  HttpClient Function(SecurityContext context)? httpClientFactory,
}) {
  final context = sharedTlsSecurityContext(
    caCertPem: caCertPem,
    caCertFilePath: caCertFilePath,
  );
  final factory = httpClientFactory ?? _labHttpClientFactory;
  final ioClient =
      factory != null ? factory(context) : HttpClient(context: context);
  return IOClient(ioClient);
}

http.Client? _defaultTlsHttpClient;

/// App-wide HTTP client with lab CA trust when configured at build time.
http.Client defaultTlsHttpClient() {
  return _defaultTlsHttpClient ??= createTlsHttpClient();
}

/// Clears the singleton client (unit tests only).
void resetDefaultTlsHttpClientForTests() {
  _defaultTlsHttpClient?.close();
  _defaultTlsHttpClient = null;
  resetSharedTlsSecurityContextForTests();
}

http.Client tlsHttpClientFromEnvironment() {
  return createTlsHttpClient();
}
