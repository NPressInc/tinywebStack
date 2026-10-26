import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/chat/chat_models.dart';
import 'package:tinyweb/src/chat/chat_service.dart';
import 'package:tinyweb/src/chat/room_screen.dart';

AppMeProfile _profile() => AppMeProfile(
      username: 'alice',
      role: 'parent',
      mxid: '@alice:family.test',
      quietHours: QuietHoursInfo(configured: false, active: false),
      eventsEnabled: true,
    );

class _FlakySendChat extends FakeChatService {
  _FlakySendChat({required super.initialRooms});

  int sendAttempts = 0;

  @override
  Future<String> sendMessage(String roomId, String body) async {
    sendAttempts++;
    if (sendAttempts == 1) {
      throw ChatSendException('network unavailable');
    }
    return super.sendMessage(roomId, body);
  }
}

void main() {
  testWidgets('attach sheet shows Photos, Videos, Camera, Record video', (tester) async {
    final chat = FakeChatService(
      initialRooms: [ChatRoom(roomId: '!r1', title: 'Room', lastTsMs: 1)],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          roomId: '!r1',
          title: 'Room',
          chat: chat,
          profile: _profile(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();

    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Videos'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Record video'), findsOneWidget);

    await chat.dispose();
  });

  testWidgets('failed send shows retry UI and retry delivers message', (tester) async {
    final chat = _FlakySendChat(
      initialRooms: [ChatRoom(roomId: '!r1', title: 'Room', lastTsMs: 1)],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          roomId: '!r1',
          title: 'Room',
          chat: chat,
          profile: _profile(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const body = 'retry me';
    await tester.enterText(find.byType(TextField), body);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(find.text(body), findsOneWidget);
    expect(find.text('Not Delivered'), findsWidgets);
    expect(find.byKey(const Key('message-retry')), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    await tester.tap(find.byKey(const Key('message-retry')));
    await tester.pumpAndSettle();

    expect(find.text(body), findsOneWidget);
    expect(find.text('Delivered'), findsOneWidget);
    expect(find.byKey(const Key('message-retry')), findsNothing);
    expect(chat.sendAttempts, 2);

    await chat.dispose();
  });
}
