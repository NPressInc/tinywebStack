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
