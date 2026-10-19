import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      enrollUrl: '/family/api/app/enroll',
    );

EnrollmentBundle _bundle() => EnrollmentBundle(
      deviceId: 'dev-1',
      username: 'parent1',
      role: 'parent',
      mxid: '@parent1:family.example',
      serverName: 'family.example',
      dashboardToken: 'secret-token',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: _discovery(),
    );

void main() {
  test('in-memory credential store round-trip', () async {
    final store = InMemoryCredentialStore();
    expect(await store.read(), isNull);

    final bundle = _bundle();
    await store.write(bundle);
    final read = await store.read();

    expect(read?.username, 'parent1');
    expect(read?.dashboardToken, 'secret-token');
    expect(read?.discovery.enrollUrl, '/family/api/app/enroll');

    await store.clear();
    expect(await store.read(), isNull);
  });
}
