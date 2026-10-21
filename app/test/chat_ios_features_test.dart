import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/chat/chat_message_mapper.dart';
import 'package:tinyweb/src/chat/chat_models.dart';
import 'package:tinyweb/src/chat/chat_reactions.dart';
import 'package:tinyweb/src/chat/chat_service.dart';
import 'package:tinyweb/src/chat/media_saver.dart';
import 'package:tinyweb/src/chat/message_bubble.dart';
import 'package:tinyweb/src/chat/room_screen.dart';
import 'package:tinyweb/src/rust/api/matrix.dart' as rust;

AppMeProfile _profile() => AppMeProfile(
      username: 'alice',
      role: 'parent',
      mxid: '@alice:family.test',
      quietHours: QuietHoursInfo(configured: false, active: false),
      eventsEnabled: true,
    );

void main() {
  test('chatMessageFromTimeline maps reactions and reply', () {
    final tm = rust.TimelineMessage(
      eventId: 'e1',
      sender: '@bob:test',
      senderDisplayName: 'Bob',
      body: 'hi',
      tsMs: 1,
      isOwn: false,
      utd: false,
      reactions: [
        rust.MessageReaction(emoji: '👍', userId: '@a:test', reactionEventId: 'r1'),
      ],
      inReplyTo: rust.ReplyPreview(
        eventId: 'e0',
        sender: '@x:test',
        senderDisplayName: 'X',
        body: 'parent',
      ),
    );
    final msg = chatMessageFromTimeline(tm);
    expect(msg.reactions, hasLength(1));
    expect(msg.inReplyTo?.body, 'parent');
  });

  testWidgets('reply quote renders in bubble', (tester) async {
    final chat = FakeChatService();
    chat.injectMessage(
      '!r',
      ChatMessage(
        eventId: 'e1',
        body: 'answer',
        senderId: '@me:family.test',
        tsMs: 2,
        isOwn: true,
        inReplyTo: ChatReplyPreview(
          eventId: 'e0',
          senderId: '@bob:test',
          body: 'question?',
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          roomId: '!r',
          title: 'R',
          chat: chat,
          profile: _profile(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reply-quote')), findsOneWidget);
    expect(find.text('question?'), findsOneWidget);
    await chat.dispose();
  });

  testWidgets('link preview card shows for URL message', (tester) async {
    final chat = FakeChatService();
    chat.injectMessage(
      '!r',
      ChatMessage(
        eventId: 'e1',
        body: 'see https://example.com/page',
        senderId: '@bob:test',
        tsMs: 1,
        isOwn: false,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          roomId: '!r',
          title: 'R',
          chat: chat,
          profile: _profile(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Example'), findsOneWidget);
    await chat.dispose();
  });

  testWidgets('reaction stack on own message is on the right', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 80,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                const SizedBox(height: 40, width: 120),
                ReactionStacks(
                  reactions: [
                    ChatReaction(emoji: '❤️', userId: '@a', reactionEventId: 'r'),
                  ],
                  isOwn: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final stack = tester.getTopLeft(find.text('❤️'));
    expect(stack.dx, greaterThan(160));
  });

  testWidgets('long-press menu offers reply and copy', (tester) async {
    final chat = FakeChatService();
    chat.injectMessage(
      '!r',
      ChatMessage(
        eventId: 'e1',
        body: 'copy me',
        senderId: '@bob:test',
        tsMs: 1,
        isOwn: false,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          roomId: '!r',
          title: 'R',
          chat: chat,
          profile: _profile(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('copy me'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('message-action-menu')), findsOneWidget);
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    await chat.dispose();
  });

  testWidgets('save button placement unchanged for media', (tester) async {
    final chat = FakeChatService();
    const ownId = 'evt_own';
    const otherId = 'evt_other';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MessageBubble(
                message: ChatMessage(
                  eventId: ownId,
                  body: '[a.png]',
                  senderId: '@me',
                  tsMs: 1,
                  isOwn: true,
                  msgtype: 'm.image',
                  filename: 'a.png',
                ),
                roomId: '!r1',
                chat: chat,
                mediaSaver: FakeMediaSaver(),
                previewMedia: false,
              ),
              MessageBubble(
                message: ChatMessage(
                  eventId: otherId,
                  body: '[b.png]',
                  senderId: '@bob',
                  tsMs: 1,
                  isOwn: false,
                  msgtype: 'm.image',
                  filename: 'b.png',
                ),
                roomId: '!r1',
                chat: chat,
                mediaSaver: FakeMediaSaver(),
                previewMedia: false,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final ownSave = tester.getCenter(find.byKey(ValueKey('media-save-$ownId')));
    final ownBubble = tester.getCenter(find.byKey(ValueKey('chat-bubble-$ownId')));
    final otherSave = tester.getCenter(find.byKey(ValueKey('media-save-$otherId')));
    final otherBubble = tester.getCenter(find.byKey(ValueKey('chat-bubble-$otherId')));
    expect(ownSave.dx < ownBubble.dx, isTrue);
    expect(otherSave.dx > otherBubble.dx, isTrue);
    await chat.dispose();
  });

  testWidgets('grouping shows date header', (tester) async {
    final chat = FakeChatService();
    final old = DateTime.now().subtract(const Duration(hours: 3)).millisecondsSinceEpoch;
    chat.injectMessage(
      '!r',
      ChatMessage(eventId: 'e1', body: 'old', senderId: '@a', tsMs: old, isOwn: false),
    );
    chat.injectMessage(
      '!r',
      ChatMessage(
        eventId: 'e2',
        body: 'new',
        senderId: '@a',
        tsMs: DateTime.now().millisecondsSinceEpoch,
        isOwn: false,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          roomId: '!r',
          title: 'R',
          chat: chat,
          profile: _profile(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Today'), findsWidgets);
    await chat.dispose();
  });
}

class FakeMediaSaver implements MediaSaver {
  @override
  Future<void> saveImage(String filePath) async {}

  @override
  Future<void> saveVideo(String filePath) async {}
}
