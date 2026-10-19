import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/push/pusher_request.dart';

void main() {
  test('http pusher uses event_id_only and gateway url', () {
    final body = buildHttpPusherSetBody(
      appId: 'win.tinyweb.tinyweb.android',
      pushkey: 'tw-deadbeef',
      gatewayUrl: 'http://127.0.0.1:8090/_matrix/push/v1/notify',
    );
    expect(body['app_id'], 'win.tinyweb.tinyweb.android');
    expect(body['pushkey'], 'tw-deadbeef');
    expect(body['data']['format'], 'event_id_only');
    expect(body['data']['url'], contains('8090'));
  });
}
