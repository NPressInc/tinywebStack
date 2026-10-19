import 'dart:convert';

/// Parse Matrix / ntfy push payloads — never use these fields for notification text.
class MatrixPushHint {
  MatrixPushHint({
    required this.eventId,
    required this.roomId,
    this.raw,
  });

  final String eventId;
  final String roomId;
  final Map<String, dynamic>? raw;

  static MatrixPushHint? tryParse(String body) {
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        json = decoded;
      }
    } catch (_) {
      return null;
    }
    if (json == null) {
      return null;
    }
    final messageField = json['message'];
    if (messageField is String) {
      try {
        final inner = jsonDecode(messageField);
        if (inner is Map<String, dynamic>) {
          json = inner;
        }
      } catch (_) {
        return null;
      }
    }
    final notification = json['notification'] as Map<String, dynamic>?;
    if (notification == null) {
      return null;
    }
    final content = notification['content'];
    final Map<String, dynamic> fields;
    if (content is Map<String, dynamic>) {
      fields = content;
    } else {
      fields = notification;
    }
    final eventId = fields['event_id'] as String? ?? fields['id'] as String?;
    final roomId = fields['room_id'] as String?;
    if (eventId == null || roomId == null) {
      return null;
    }
    return MatrixPushHint(eventId: eventId, roomId: roomId, raw: json);
  }

  /// True when the payload might contain human-readable message content (forbidden).
  static bool containsForbiddenMessageContent(Map<String, dynamic> json) {
    final notification = json['notification'] as Map<String, dynamic>?;
    if (notification == null) {
      return false;
    }
    for (final candidate in [
      notification['content'],
      notification,
    ]) {
      if (candidate is! Map<String, dynamic>) {
        continue;
      }
      if (candidate['body'] != null || candidate['msgtype'] != null) {
        return true;
      }
      if (candidate['sender_display_name'] != null ||
          candidate['room_name'] != null) {
        return true;
      }
      final inner = candidate['content'];
      if (inner is Map && (inner['body'] != null || inner['msgtype'] != null)) {
        return true;
      }
    }
    return false;
  }
}
