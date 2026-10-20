import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/lab_ca_config.dart';
import 'package:tinyweb/src/api/tls_http_client.dart';

const _samplePem = '''-----BEGIN CERTIFICATE-----
MIIBkTCB+wIJAKHBfpEDwN2OMA0GCSqGSIb3DQEBCwUAMBQxEjAQBgNVBAoMCWxh
Yi1jYS10ZXN0MBYxEzARBgNVBAMMCmxhYi1jYS10ZXN0MA0GCSqGSIb3DQEBCwUA
A4IBAQCdummy
-----END CERTIFICATE-----
''';

void main() {
  tearDown(() {
    resetDefaultTlsHttpClientForTests();
  });

  test('labCaPemFromDartDefine is empty without build flag', () {
    expect(labCaPemFromDartDefine(), isNull);
  });

  test('resolveLabCaPem prefers explicit PEM and reads file path', () async {
    expect(resolveLabCaPem(caCertPem: 'custom'), 'custom');
    final dir = await Directory.systemTemp.createTemp('tw_lab_ca');
    final caFile = File('${dir.path}/ca.pem');
    await caFile.writeAsString(_samplePem);
    try {
      expect(resolveLabCaPem(caCertFilePath: caFile.path), _samplePem);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('sharedTlsSecurityContext caches by resolved PEM', () {
    resetDefaultTlsHttpClientForTests();
    final a = sharedTlsSecurityContext();
    final b = sharedTlsSecurityContext();
    expect(identical(a, b), isTrue);
  });

  test('createTlsHttpClient returns IO-backed client', () {
    resetDefaultTlsHttpClientForTests();
    final client = createTlsHttpClient();
    client.close();
  });
}
