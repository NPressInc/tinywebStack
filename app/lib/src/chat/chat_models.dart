class ChatRoom {
  ChatRoom({
    required this.roomId,
    required this.title,
    this.lastMessage,
    this.lastTsMs,
    this.unread = 0,
    this.isDirect = false,
  });

  final String roomId;
  final String title;
  final String? lastMessage;
  final int? lastTsMs;
  final int unread;
  final bool isDirect;
}

class ChatMessage {
  ChatMessage({
    required this.eventId,
    required this.body,
    required this.senderId,
    this.senderDisplayName,
    required this.tsMs,
    required this.isOwn,
  });

  final String eventId;
  final String body;
  final String senderId;
  final String? senderDisplayName;
  final int tsMs;
  final bool isOwn;

  String get senderLabel => senderDisplayName ?? senderId;
}
