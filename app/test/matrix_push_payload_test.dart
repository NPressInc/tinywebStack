import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/push/matrix_push_payload.dart';

void main() {
  test('parses Synapse event_id_only notification (no content key)', () {
    final raw = jsonEncode({
      'notification': {
        'event_id': r'$abc',
        'room_id': '!r:hs',
        'counts': {'unread': 1},
        'prio': 'high',
        'devices': [
          {
            'pushkey': 'https://push.example.com/upabc?up=1',
            'app_id': 'test',
          },
        ],
      },
    });
    final hint = MatrixPushHint.tryParse(raw);
    expect(hint, isNotNull);
    expect(hint!.eventId, r'$abc');
    expect(hint.roomId, '!r:hs');
  });

  test('parses legacy content-wrapped notification', () {
    const raw = '''
{"notification":{"content":{"event_id":"\$abc","room_id":"!r:hs","prio":"high"}}}
''';
    final hint = MatrixPushHint.tryParse(raw);
    expect(hint, isNotNull);
    expect(hint!.eventId, r'$abc');
    expect(hint.roomId, '!r:hs');
  });

  test('parses ntfy json stream wrapper', () {
    final inner = jsonEncode({
      'notification': {
        'event_id': r'$e1',
        'room_id': '!r:hs',
        'counts': {'unread': 1},
      },
    });
    final wrapped = jsonEncode({'message': inner});
    final hint = MatrixPushHint.tryParse(wrapped);
    expect(hint, isNotNull);
    expect(hint!.eventId, r'$e1');
  });

  test('flags forbidden message content in payload', () {
    final json = {
      'notification': {
        'content': {
          'event_id': r'$e',
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
        'event_id': r'$e',
        'room_id': '!r:hs',
        'counts': {'unread': 1},
      },
    };
    expect(MatrixPushHint.containsForbiddenMessageContent(json), isFalse);
  });
}
