import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/chat/chat_link_preview.dart';
import 'package:tinyweb/src/chat/chat_models.dart';
import 'package:tinyweb/src/chat/chat_service.dart';
import 'package:tinyweb/src/chat/message_bubble.dart';

ChatMessage _linkMessage(String eventId, String body) {
  return ChatMessage(
    eventId: eventId,
    body: body,
    senderId: '@alice:family.test',
    senderDisplayName: 'Alice',
    tsMs: 1_700_000_000_000,
    isOwn: false,
  );
}

Widget _bubbleList(FakeChatService chat, List<ChatMessage> messages) {
  return MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          for (final m in messages)
            MessageBubble(
              message: m,
              roomId: '!room:family.test',
              chat: chat,
              previewMedia: false,
              showSenderName: false,
              showTimestamp: false,
            ),
        ],
      ),
    ),
  );
}

void main() {
  setUp(clearUrlPreviewCaches);

  testWidgets('disabled preview response shows no preview card', (tester) async {
    final chat = FakeChatService();
    chat.urlPreviewError = Exception('url_preview_unavailable');
    await tester.pumpWidget(
      _bubbleList(chat, [_linkMessage('e1', 'see https://example.com/a')]),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatLinkPreviewCard), findsNothing);
    expect(chat.urlPreviewFetchCount, 1);
  });

  testWidgets('homeserver disabled after first failure skips further preview requests', (tester) async {
    final chat = FakeChatService();
    chat.urlPreviewError = Exception('M_UNRECOGNIZED');
    await tester.pumpWidget(
      _bubbleList(chat, [
        _linkMessage('e1', 'one https://example.com/a'),
        _linkMessage('e2', 'two https://other.test/b'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatLinkPreviewCard), findsNothing);
    expect(chat.urlPreviewFetchCount, 1);
  });

  testWidgets('same URL in two messages triggers one preview fetch', (tester) async {
    final chat = FakeChatService();
    await tester.pumpWidget(
      _bubbleList(chat, [
        _linkMessage('e1', 'a https://example.com/shared'),
        _linkMessage('e2', 'b https://example.com/shared'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatLinkPreviewCard), findsNWidgets(2));
    expect(chat.urlPreviewFetchCount, 1);
  });

  testWidgets('links remain tappable when preview is unavailable', (tester) async {
    final chat = FakeChatService();
    chat.urlPreviewError = Exception('url_preview_unavailable');
    await tester.pumpWidget(
      _bubbleList(chat, [_linkMessage('e1', 'see https://example.com/tap-me')]),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Linkify), findsOneWidget);
    expect(find.textContaining('example.com'), findsWidgets);
  });
}
