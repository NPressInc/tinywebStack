import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/enroll/secure_recovery_screen.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

void main() {
  testWidgets('secure recovery enter-key UI', (tester) async {
    final store = InMemoryCredentialStore();
    await store.setMatrixE2eeSetupComplete();
    final session = AppSession(store: store);
    session.enrollment = EnrollmentBundle(
      deviceId: 'd',
      username: 'kid1',
      role: 'kid',
      mxid: '@kid1:family.example',
      serverName: 'family.example',
      dashboardToken: 'tok',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: FamilyDiscovery(serverOrigin: 'https://family.example'),
      rawJson: {
        'matrix': {
          'status': 'ok',
          'access_token': 't',
          'device_id': 'dev',
          'user_id': '@kid1:family.example',
          'homeserver': 'https://matrix.example',
        },
      },
    );
    session.route = AppRoute.secureChats;

    await tester.pumpWidget(
      MaterialApp(
        home: SecureRecoveryScreen(session: session),
      ),
    );
    await tester.pump();

    expect(find.text('Secure your chats'), findsOneWidget);
  });
}
