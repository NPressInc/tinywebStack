import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Optional hook for `lab_test/lab_env.dart` when `TW_RESOLVE_IP` is set.
HttpClient Function(SecurityContext context)? _labHttpClientFactory;

void registerLabHttpClientFactory(
  HttpClient Function(SecurityContext context)? factory,
) {
  _labHttpClientFactory = factory;
}

/// HTTP client that trusts an extra PEM CA (e.g. lab `TW_CA_FILE` on the host).
http.Client createTlsHttpClient({
  String? caCertPem,
  String? caCertFilePath,
  HttpClient Function(SecurityContext context)? httpClientFactory,
}) {
  String? pem = caCertPem;
  if ((pem == null || pem.isEmpty) && caCertFilePath != null && caCertFilePath.isNotEmpty) {
    pem = File(caCertFilePath).readAsStringSync();
  }
  if (pem == null || pem.isEmpty) {
    return http.Client();
  }
  final context = SecurityContext(withTrustedRoots: true)
    ..setTrustedCertificatesBytes(utf8.encode(pem));
  final factory = httpClientFactory ?? _labHttpClientFactory;
  final ioClient = factory != null ? factory(context) : HttpClient(context: context);
  return IOClient(ioClient);
}

http.Client tlsHttpClientFromEnvironment() {
  final path = Platform.environment['TW_CA_FILE'];
  return createTlsHttpClient(caCertFilePath: path);
}
