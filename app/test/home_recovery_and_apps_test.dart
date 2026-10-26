import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/home/home_screen.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      enrollUrl: '/family/api/app/enroll',
    );

AppSession _session({CredentialStore? store}) {
  final session = AppSession(store: store ?? InMemoryCredentialStore());
  session.enrollment = EnrollmentBundle(
    deviceId: 'd',
    username: 'alice',
    role: 'parent',
    mxid: '@alice:family.example',
    serverName: 'family.example',
    dashboardToken: 'tok',
    apiBase: '/family/api',
    serverOrigin: 'https://family.example',
    discovery: _discovery(),
    rawJson: {
      'matrix': {
        'status': 'ok',
        'access_token': 't',
        'device_id': 'dev',
        'user_id': '@alice:family.example',
        'homeserver': 'https://matrix.example',
      },
    },
  );
  session.profile = AppMeProfile(
    username: 'alice',
    role: 'parent',
    mxid: '@alice:family.example',
    quietHours: QuietHoursInfo(
      configured: true,
      active: false,
      windowEnd: '8:00',
    ),
    eventsEnabled: true,
  );
  session.route = AppRoute.home;
  return session;
}

Future<void> _openRecoveryMenu(WidgetTester tester) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Chat recovery key'));
  await tester.pumpAndSettle();
}

void main() {
  String? clipboardText;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments as Map<dynamic, dynamic>;
        clipboardText = args['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('recovery key dialog copy and enter different key', (tester) async {
    final store = InMemoryCredentialStore();
    await store.writeMatrixRecoveryKey('REC-KEY-9999');
    await store.setMatrixE2eeSetupComplete();
    final session = _session(store: store);

    await tester.pumpWidget(MaterialApp(home: HomeScreen(session: session)));
    await _openRecoveryMenu(tester);

    expect(find.text('REC-KEY-9999'), findsOneWidget);

    await tester.tap(find.text('Copy key'));
    await tester.pumpAndSettle();
    expect(clipboardText, 'REC-KEY-9999');

    await tester.tap(find.text('Enter a different key'));
    await tester.pumpAndSettle();

    expect(find.text('Secure your chats'), findsOneWidget);
  });

  testWidgets('recovery menu without key opens SecureRecoveryScreen', (tester) async {
    final store = InMemoryCredentialStore();
    await store.setMatrixE2eeSetupComplete();
    final session = _session(store: store);

    await tester.pumpWidget(MaterialApp(home: HomeScreen(session: session)));
    await _openRecoveryMenu(tester);

    expect(find.text('Secure your chats'), findsOneWidget);
    expect(find.text('REC-KEY-9999'), findsNothing);
  });

  testWidgets('other family apps sheet copies server URL and username', (tester) async {
    final session = _session();

    await tester.pumpWidget(MaterialApp(home: HomeScreen(session: session)));
    await tester.tap(find.text('Other family apps'));
    await tester.pumpAndSettle();

    expect(find.text('Other family apps (Jellyfin, etc.)'), findsOneWidget);
    expect(find.text('https://family.example'), findsOneWidget);
    expect(find.text('alice'), findsWidgets);

    await tester.tap(find.text('Copy server URL'));
    await tester.pumpAndSettle();
    expect(clipboardText, 'https://family.example');

    await tester.tap(find.text('Copy username'));
    await tester.pumpAndSettle();
    expect(clipboardText, 'alice');
  });
}
