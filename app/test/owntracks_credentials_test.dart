import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';

void main() {
  test('parses kid publish credentials from enrollment', () {
    final discovery = FamilyDiscovery(
      serverOrigin: 'https://family.example',
      enrollUrl: '/family/api/app/enroll',
    );
    final bundle = EnrollmentBundle.fromJson(
      {
        'device_id': 'd1',
        'username': 'kid1',
        'role': 'kid',
        'mxid': '@kid1:family.example',
        'server_name': 'family.example',
        'dashboard': {'token': 't', 'api_base': '/family/api'},
        'owntracks': {
          'url': 'https://owntracks.example/recorder/pub',
          'username': 'kid1',
          'device': 'kid1-phone',
          'password': 'secret',
          'tid': 'k1',
          'publish': true,
          'mode': 'http',
        },
      },
      'https://family.example',
      discovery,
    );
    final creds = bundle.owntracksCredentials!;
    expect(creds.url, contains('/recorder/pub'));
    expect(creds.device, 'kid1-phone');
    expect(creds.tid, 'k1');
    expect(creds.shouldPublish, isTrue);
  });

  test('parent enrollment has no publish credentials', () {
    final discovery = FamilyDiscovery(
      serverOrigin: 'https://family.example',
      enrollUrl: '/family/api/app/enroll',
    );
    final bundle = EnrollmentBundle.fromJson(
      {
        'device_id': 'd1',
        'username': 'parent1',
        'role': 'parent',
        'mxid': '@parent1:family.example',
        'server_name': 'family.example',
        'dashboard': {'token': 't', 'api_base': '/family/api'},
        'owntracks': {'status': 'not_needed'},
      },
      'https://family.example',
      discovery,
    );
    expect(bundle.owntracksCredentials, isNull);
  });
}
