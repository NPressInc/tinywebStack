import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';

void main() {
  test('mobilizon credentials from enrollment json', () {
    final discovery = FamilyDiscovery(
      serverOrigin: 'https://family.example',
      eventsUrl: 'https://mobilizon.family.example',
    );
    final bundle = EnrollmentBundle(
      deviceId: 'd',
      username: 'kid',
      role: 'kid',
      mxid: '@kid:family.example',
      serverName: 'family.example',
      dashboardToken: 't',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: discovery,
      rawJson: {
        'mobilizon': {
          'status': 'ok',
          'access_token': 'abc',
        },
      },
    );
    final creds = bundle.mobilizonCredentials;
    expect(creds, isNotNull);
    expect(creds!.apiUrl, 'https://mobilizon.family.example/api');
    expect(creds.accessToken, 'abc');
  });

  test('code enrollment mobilizon password_required yields null', () {
    final discovery = FamilyDiscovery(serverOrigin: 'https://family.example');
    final bundle = EnrollmentBundle(
      deviceId: 'd',
      username: 'kid',
      role: 'kid',
      mxid: '@kid:family.example',
      serverName: 'family.example',
      dashboardToken: 't',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: discovery,
      rawJson: {
        'mobilizon': {'status': 'password_required'},
      },
    );
    expect(bundle.mobilizonCredentials, isNull);
  });
}
