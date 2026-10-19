import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// HTTP client that trusts an extra PEM CA (e.g. lab `TW_CA_FILE` on the host).
http.Client createTlsHttpClient({String? caCertPem, String? caCertFilePath}) {
  String? pem = caCertPem;
  if ((pem == null || pem.isEmpty) && caCertFilePath != null && caCertFilePath.isNotEmpty) {
    pem = File(caCertFilePath).readAsStringSync();
  }
  if (pem == null || pem.isEmpty) {
    return http.Client();
  }
  final context = SecurityContext(withTrustedRoots: true)
    ..setTrustedCertificatesBytes(utf8.encode(pem));
  return IOClient(HttpClient(context: context));
}

http.Client tlsHttpClientFromEnvironment() {
  final path = Platform.environment['TW_CA_FILE'];
  return createTlsHttpClient(caCertFilePath: path);
}
