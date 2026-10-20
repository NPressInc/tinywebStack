import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/api/tls_http_client.dart';

class _CloseTrackingClient extends http.BaseClient {
  _CloseTrackingClient(this.inner);

  final http.Client inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (closed) {
      throw StateError('client is closed');
    }
    return inner.send(request);
  }

  @override
  void close() {
    closed = true;
    inner.close();
  }
}

FamilyDiscovery _discovery() {
  return FamilyDiscovery(
    serverOrigin: 'https://family.example',
    enrollUrl: '/family/api/app/enroll',
    serverName: 'family.example',
  );
}

void main() {
  tearDown(resetDefaultTlsHttpClientForTests);

  test('closing one FamilyApiClient does not close the default singleton', () async {
    final mock = MockClient((_) async => http.Response(
          jsonEncode({
            'device_id': 'd1',
            'username': 'kid1',
            'role': 'kid',
            'mxid': '@kid1:family.example',
            'server_name': 'family.example',
            'dashboard': {'token': 'tok', 'api_base': '/family/api'},
          }),
          200,
        ));
    final tracking = _CloseTrackingClient(mock);
    setDefaultTlsHttpClientForTests(tracking);

    final a = FamilyApiClient();
    final b = FamilyApiClient();
    a.close();
    expect(tracking.closed, isFalse);

    final bundle = await b.enroll(
      discovery: _discovery(),
      method: 'code',
      code: 'ABC',
    );
    expect(bundle.dashboardToken, 'tok');
    expect(tracking.closed, isFalse);
    b.close();
    expect(tracking.closed, isFalse);
  });

  test('FamilyApiClient closes an injected client it owns', () {
    final mock = MockClient((_) async => http.Response('{}', 200));
    final tracking = _CloseTrackingClient(mock);
    final api = FamilyApiClient(client: tracking);
    api.close();
    expect(tracking.closed, isTrue);
  });
}
