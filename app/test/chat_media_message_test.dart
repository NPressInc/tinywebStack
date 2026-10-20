import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/chat/chat_models.dart';
import 'package:tinyweb/src/chat/chat_service.dart';
import 'package:tinyweb/src/chat/message_bubble.dart';

void main() {
  testWidgets('MessageBubble loads image media via chat service', (tester) async {
    final chat = FakeChatService();
    const eventId = 'evt_img';
    final message = ChatMessage(
      eventId: eventId,
      body: '[dot.png]',
      senderId: '@bob:family.test',
      tsMs: 1,
      isOwn: false,
      msgtype: 'm.image',
      filename: 'dot.png',
      mimeType: 'image/png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            roomId: '!r1',
            chat: chat,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Could not load image'), findsOneWidget);
    await chat.dispose();
  });

  testWidgets('MessageBubble shows video poster and play affordance', (tester) async {
    final chat = FakeChatService();
    const eventId = 'evt_vid';
    chat.thumbnailPaths[eventId] = '/tmp/not-used.png';
    chat.mediaPaths[eventId] = '/tmp/not-used.mp4';
    final message = ChatMessage(
      eventId: eventId,
      body: 'clip',
      senderId: '@bob:family.test',
      tsMs: 1,
      isOwn: false,
      msgtype: 'm.video',
      filename: 'clip.mp4',
      mimeType: 'video/mp4',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            roomId: '!r1',
            chat: chat,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(find.text('clip'), findsOneWidget);
    await chat.dispose();
  });

  test('ChatMessage media helpers', () {
    final img = ChatMessage(
      eventId: 'e',
      body: '[photo.jpg]',
      senderId: '@a:b',
      tsMs: 0,
      isOwn: true,
      msgtype: 'm.image',
      filename: 'photo.jpg',
    );
    expect(img.isImage, isTrue);
    expect(img.mediaCaption, isNull);

    final withCap = ChatMessage(
      eventId: 'e2',
      body: 'sunset',
      senderId: '@a:b',
      tsMs: 0,
      isOwn: true,
      msgtype: 'm.image',
      filename: 'photo.jpg',
    );
    expect(withCap.mediaCaption, 'sunset');
  });
}
