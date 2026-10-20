import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/chat/chat_linkify.dart';

void main() {
  test('linkify extracts https URLs from message text', () {
    final elements = linkify('see https://example.com/path ok');
    expect(
      elements.whereType<UrlElement>().map((e) => e.url),
      contains('https://example.com/path'),
    );
  });

  testWidgets('ChatLinkifyText builds Linkify widget', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatLinkifyText(
            text: 'see https://example.com/path ok',
            style: TextStyle(),
            linkColor: Colors.blue,
          ),
        ),
      ),
    );

    expect(find.byType(Linkify), findsOneWidget);
  });
}
