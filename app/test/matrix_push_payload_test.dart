import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/push/matrix_push_payload.dart';

void main() {
  test('parses event_id_only notification', () {
    const raw = '''
{"notification":{"content":{"event_id":"\$abc","room_id":"!r:hs","prio":"high"}}}
''';
    final hint = MatrixPushHint.tryParse(raw);
    expect(hint, isNotNull);
    expect(hint!.eventId, '\$abc');
    expect(hint.roomId, '!r:hs');
  });

  test('flags forbidden message content in payload', () {
    final json = {
      'notification': {
        'content': {
          'event_id': '\$e',
          'room_id': '!r:hs',
          'body': 'secret',
        },
      },
    };
    expect(MatrixPushHint.containsForbiddenMessageContent(json), isTrue);
  });

  test('event_id_only shape is not forbidden', () {
    final json = {
      'notification': {
        'content': {
          'event_id': '\$e',
          'room_id': '!r:hs',
          'counts': {'unread': 1},
        },
      },
    };
    expect(MatrixPushHint.containsForbiddenMessageContent(json), isFalse);
  });
}
