import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/family/link_invite_token.dart';

void main() {
  test('parses bare token', () {
    expect(parseLinkInviteToken('abc.token'), 'abc.token');
  });

  test('parses redeem URL query', () {
    expect(
      parseLinkInviteToken(
        'https://family-a.test/family/invite/redeem?token=eyJhbG',
      ),
      'eyJhbG',
    );
  });
}
