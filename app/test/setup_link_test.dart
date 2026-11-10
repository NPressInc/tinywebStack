import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/enroll/enroll_link.dart';
import 'package:tinyweb/src/setup/setup_discovery.dart';
import 'package:tinyweb/src/setup/setup_link.dart';

void main() {
  const token = 'box-setup-code-22';

  test('reads the setup code from the fragment only', () {
    expect(parseSetupCode(token).code, token);
    expect(
      parseSetupCode('https://tinyweb.win/setup#code=$token').code,
      token,
    );
    expect(parseSetupCode('tinyweb://setup#code=$token').code, token);
    expect(looksLikeSetupLink('https://tinyweb.win/setup#code=$token'), isTrue);
    expect(looksLikeSetupLink('tinyweb://setup#code=$token'), isTrue);
  });

  test('rejects a setup code placed in the query string', () {
    final parsed = parseSetupCode('https://tinyweb.win/setup?code=$token');
    expect(parsed.code, isNull);
    expect(parsed.error, contains('wrong place'));
    expect(parsed.error, isNot(contains(token)));
  });

  test('a setup link is not an enrollment link', () {
    final enroll = parseEnrollLink('https://tinyweb.win/setup#code=$token');
    expect(enroll.code, isNull);
    expect(enroll.serverOrigin, isNull);
    final join = parseEnrollLink('https://floyd.tinyweb.win/family/join#code=ABCD2345');
    expect(join.code, 'ABCD2345');
  });

  test('beacon uses the sender address and ignores public hosts', () {
    final packet = utf8.encode(
      '{"v":1,"service":"tinyweb-setup","port":4734,"host":"tinyweb.local"}',
    );
    final box = discoveredBoxFromBeacon(packet, '192.168.1.20');
    expect(box?.ip, '192.168.1.20');
    expect(box?.port, 4734);
    expect(box?.hostLabel, 'tinyweb.local');
    expect(discoveredBoxFromBeacon(packet, '8.8.8.8'), isNull);
    expect(isLocalSetupPeer('10.1.2.3'), isTrue);
    expect(isLocalSetupPeer('172.16.0.4'), isTrue);
  });
}
