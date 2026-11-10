import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/enroll/setup_checklist.dart';
import 'package:tinyweb/src/enroll/setup_ready_screen.dart';

void main() {
  testWidgets('checklist shows linked services and the remaining step', (tester) async {
    final discovery = FamilyDiscovery(
      serverOrigin: 'https://smith.tinyweb.win',
      serverName: 'smith.tinyweb.win',
      enrollUrl: '/family/api/app/enroll',
    );
    final bundle = EnrollmentBundle(
      deviceId: 'd1',
      username: 'kid1',
      role: 'kid',
      mxid: '@kid1:smith.tinyweb.win',
      serverName: 'smith.tinyweb.win',
      dashboardToken: 'tok',
      apiBase: '/family/api',
      serverOrigin: 'https://smith.tinyweb.win',
      discovery: discovery,
      rawJson: {
        'matrix': {
          'status': 'ok',
          'access_token': 'matrix-token',
          'device_id': 'MX',
        },
        'caldav': {
          'root': 'https://nextcloud.smith.tinyweb.win/remote.php/dav',
          'username': 'kid1',
          'password': 'caldav-secret',
        },
        'mobilizon': {'status': 'password_required'},
        'owntracks': {
          'url': 'https://owntracks.smith.tinyweb.win/recorder/pub',
          'username': 'kid1',
          'device': 'phone',
          'password': 'location-secret',
          'tid': 'k1',
          'publish': true,
          'mode': 'http',
        },
      },
    );
    final checklist = describeSetup(
      bundle,
      needsRecovery: true,
      needsLocation: true,
    );
    var continued = false;
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: SetupReadyScreen(
          checklist: checklist,
          onContinue: () => continued = true,
        ),
      ),
    );

    expect(find.text("You're all set"), findsOneWidget);
    expect(find.text('Signed in as kid1 on smith.tinyweb.win.'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Calendar'), findsOneWidget);
    expect(find.text('Events'), findsOneWidget);
    expect(find.text('Location'), findsOneWidget);
    expect(find.textContaining('family password'), findsWidgets);
    expect(find.textContaining('Save the chat recovery key'), findsOneWidget);
    expect(find.textContaining('caldav-secret'), findsNothing);
    expect(find.textContaining('location-secret'), findsNothing);
    expect(find.textContaining('matrix-token'), findsNothing);

    await tester.tap(find.byKey(const Key('setup-continue')));
    await tester.pump();
    expect(continued, isTrue);
    expect(find.text('Continue — save chat recovery key'), findsOneWidget);
  });
}