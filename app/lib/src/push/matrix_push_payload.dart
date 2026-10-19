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
    final notification = json['notification'] as Map<String, dynamic>?;
    final content = (notification?['content'] as Map<String, dynamic>?) ?? json;
    final eventId = content['event_id'] as String? ?? content['id'] as String?;
    final roomId = content['room_id'] as String?;
    if (eventId == null || roomId == null) {
      return null;
    }
    return MatrixPushHint(eventId: eventId, roomId: roomId, raw: json);
  }

  /// True when the payload might contain human-readable message content (forbidden).
  static bool containsForbiddenMessageContent(Map<String, dynamic> json) {
    final notification = json['notification'] as Map<String, dynamic>?;
    final content = notification?['content'];
    if (content is! Map<String, dynamic>) {
      return false;
    }
    if (content['body'] != null || content['msgtype'] != null) {
      return true;
    }
    if (content['sender_display_name'] != null || content['room_name'] != null) {
      return true;
    }
    final inner = content['content'];
    if (inner is Map && (inner['body'] != null || inner['msgtype'] != null)) {
      return true;
    }
    return false;
  }
}
