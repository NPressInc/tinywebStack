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
