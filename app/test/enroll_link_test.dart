import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/enroll/enroll_link.dart';

void main() {
  test('parses tinyweb enroll deep link', () {
    final data = parseEnrollLink(
      'tinyweb://enroll?server=family.example&code=ABC123',
    );
    expect(data.serverOrigin, 'https://family.example');
    expect(data.code, 'ABC123');
  });

  test('parses tinyweb enroll deep link with bare family slug', () {
    final data = parseEnrollLink(
      'tinyweb://enroll?server=smith&code=ABC',
    );
    expect(data.serverOrigin, 'https://smith.tinyweb.win');
    expect(data.code, 'ABC');
  });

  test('normalizeFamilyServerInput expands bare slug and preserves full domains', () {
    expect(normalizeFamilyServerInput('smith'), 'smith.tinyweb.win');
    expect(
      normalizeFamilyServerInput('https://smith'),
      'https://smith.tinyweb.win',
    );
    expect(
      normalizeFamilyServerInput('family-b.family.test'),
      'family-b.family.test',
    );
  });

  test('normalizeServerOrigin expands bare family slug', () {
    expect(normalizeServerOrigin('smith'), 'https://smith.tinyweb.win');
  });

  test('normalizeEnteredMxid expands bare server name', () {
    expect(normalizeEnteredMxid('@dad:jones'), '@dad:jones.tinyweb.win');
    expect(normalizeEnteredMxid('dad:jones'), '@dad:jones.tinyweb.win');
    expect(
      normalizeEnteredMxid('@dad:family-a.family.test'),
      '@dad:family-a.family.test',
    );
  });

  test('parses https join link with the code in the fragment', () {
    final data = parseEnrollLink(
      'https://smith.tinyweb.win/family/join#code=ABCD2345',
    );
    expect(data.serverOrigin, 'https://smith.tinyweb.win');
    expect(data.serverHost, 'smith.tinyweb.win');
    expect(data.code, 'ABCD2345');
  });

  test('parses https join link with a query code and ignores a password', () {
    final data = parseEnrollLink(
      'https://family.example/family/join?code=ABCD2345&password=secret-token',
    );
    expect(data.serverOrigin, 'https://family.example');
    expect(data.code, 'ABCD2345');
    expect(data.toString(), isNot(contains('secret-token')));
  });

  test('setup link is not treated as family enrollment', () {
    final data = parseEnrollLink('https://tinyweb.win/setup#code=box-setup-code-22');
    expect(data.code, isNull);
    expect(data.serverOrigin, isNull);
  });

  test('parses bare enroll code', () {
    final data = parseEnrollLink('XYZZY99');
    expect(data.code, 'XYZZY99');
    expect(data.serverOrigin, isNull);
  });

  test('normalises server without scheme', () {
    expect(normalizeServerOrigin('family.example'), 'https://family.example');
    expect(normalizeServerOrigin('https://family.example/'), 'https://family.example');
  });

  test('rejects plain http except localhost in debug', () {
    expect(
      normalizeServerOrigin('http://family.example', allowInsecureLocalhost: true),
      isNull,
    );
    expect(
      normalizeServerOrigin('http://localhost', allowInsecureLocalhost: true),
      'http://localhost',
    );
    expect(
      normalizeServerOrigin('http://10.0.2.2', allowInsecureLocalhost: true),
      'http://10.0.2.2',
    );
  });
}
