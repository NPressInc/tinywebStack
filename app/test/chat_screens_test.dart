import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/app_session.dart';
import 'package:tinyweb/src/chat/chat_list_screen.dart';
import 'package:tinyweb/src/chat/chat_models.dart';
import 'package:tinyweb/src/chat/chat_service.dart';
import 'package:tinyweb/src/chat/room_screen.dart';
import 'package:tinyweb/src/storage/credential_store.dart';

AppSession _session({required String role, bool quietActive = false}) {
  final session = AppSession(store: InMemoryCredentialStore());
  session.enrollment = EnrollmentBundle(
    deviceId: 'd',
    username: 'alice',
    role: role,
    mxid: '@alice:family.example',
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
        'user_id': '@alice:family.example',
        'homeserver': 'https://matrix.example',
      },
    },
  );
  session.profile = AppMeProfile(
    username: 'alice',
    role: role,
    mxid: '@alice:family.example',
    quietHours: QuietHoursInfo(
      configured: true,
      active: quietActive,
      windowEnd: '8:00',
    ),
    eventsEnabled: true,
  );
  session.route = AppRoute.home;
  return session;
}

void main() {
  testWidgets('ChatListScreen shows rooms sorted by recency', (tester) async {
    final chat = FakeChatService(
      initialRooms: [
        ChatRoom(
          roomId: '!a',
          title: 'Older',
          lastMessage: 'hi',
          lastTsMs: 1000,
        ),
        ChatRoom(
          roomId: '!b',
          title: 'Newer',
          lastMessage: 'yo',
          lastTsMs: 5000,
        ),
      ],
    );
    await chat.refreshRooms();

    await tester.pumpWidget(
      MaterialApp(
        home: ChatListScreen(session: _session(role: 'parent'), chat: chat),
      ),
    );

    expect(find.text('Newer'), findsOneWidget);
    expect(find.text('Older'), findsOneWidget);
    final newerFinder = find.text('Newer');
    final olderFinder = find.text('Older');
    expect(
      tester.getTopLeft(newerFinder).dy < tester.getTopLeft(olderFinder).dy,
      isTrue,
    );

    await tester.tap(find.text('Newer'));
    await tester.pumpAndSettle();
    expect(find.byType(RoomScreen), findsOneWidget);
  });

  testWidgets('RoomScreen sends message via fake chat', (tester) async {
    final chat = FakeChatService(
      initialRooms: [
        ChatRoom(roomId: '!r1', title: 'Room', lastTsMs: 1),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          roomId: '!r1',
          title: 'Room',
          chat: chat,
          profile: _session(role: 'parent').profile!,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'hello there');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(find.text('hello there'), findsOneWidget);
  });

  testWidgets('RoomScreen shows forbidden banner', (tester) async {
    final chat = FakeChatService(
      initialRooms: [ChatRoom(roomId: '!r1', title: 'Room', lastTsMs: 1)],
    );
    chat.forbiddenSend = true;

    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          roomId: '!r1',
          title: 'Room',
          chat: chat,
          profile: _session(role: 'kid').profile!,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nope');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(find.textContaining('Not allowed:'), findsOneWidget);
  });

  testWidgets('RoomScreen shows quiet-hours banner for kid', (tester) async {
    final chat = FakeChatService(
      initialRooms: [ChatRoom(roomId: '!r1', title: 'Room', lastTsMs: 1)],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          roomId: '!r1',
          title: 'Room',
          chat: chat,
          profile: _session(role: 'kid', quietActive: true).profile!,
        ),
      ),
    );

    expect(find.textContaining('Quiet hours'), findsOneWidget);
  });

  testWidgets('ChatList shows lock for encrypted rooms', (tester) async {
    final chat = FakeChatService(
      initialRooms: [
        ChatRoom(
          roomId: '!enc',
          title: 'Secret',
          encrypted: true,
          lastTsMs: 100,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChatListScreen(session: _session(role: 'parent'), chat: chat),
      ),
    );

    expect(find.byIcon(Icons.lock), findsOneWidget);
  });

  testWidgets('RoomScreen styles unable-to-decrypt messages', (tester) async {
    final chat = FakeChatService(
      initialRooms: [ChatRoom(roomId: '!r1', title: 'Room', lastTsMs: 1)],
    );
    chat.injectMessage(
      '!r1',
      ChatMessage(
        eventId: 'e1',
        body:
            'Unable to decrypt — sent before this device joined, or restore your recovery key',
        senderId: '@bob:family.test',
        tsMs: 1,
        isOwn: false,
        utd: true,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          roomId: '!r1',
          title: 'Room',
          chat: chat,
          profile: _session(role: 'parent').profile!,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Unable to decrypt — sent before this device joined, or restore your recovery key',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('Chat not set up without matrix creds', (tester) async {
    final session = AppSession(store: InMemoryCredentialStore());
    session.enrollment = EnrollmentBundle(
      deviceId: 'd',
      username: 'alice',
      role: 'kid',
      mxid: '@alice:family.example',
      serverName: 'family.example',
      dashboardToken: 'tok',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: FamilyDiscovery(serverOrigin: 'https://family.example'),
      rawJson: {'matrix': {'status': 'pending'}},
    );
    session.profile = _session(role: 'kid').profile;
    session.route = AppRoute.home;

    await tester.pumpWidget(
      MaterialApp(
        home: ChatListScreen(
          session: session,
          chat: UnconfiguredChatService(),
        ),
      ),
    );

    expect(
      find.textContaining("Chat isn't set up for this device yet"),
      findsOneWidget,
    );
  });
}
