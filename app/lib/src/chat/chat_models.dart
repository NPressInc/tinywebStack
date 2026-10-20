class ChatRoom {
  ChatRoom({
    required this.roomId,
    required this.title,
    this.lastMessage,
    this.lastTsMs,
    this.unread = 0,
    this.isDirect = false,
    this.encrypted = false,
  });

  final String roomId;
  final String title;
  final String? lastMessage;
  final int? lastTsMs;
  final int unread;
  final bool isDirect;
  final bool encrypted;
}

class ChatMessage {
  ChatMessage({
    required this.eventId,
    required this.body,
    required this.senderId,
    this.senderDisplayName,
    required this.tsMs,
    required this.isOwn,
    this.utd = false,
    this.msgtype,
    this.filename,
    this.mimeType,
    this.width,
    this.height,
    this.durationMs,
  });

  final String eventId;
  final String body;
  final String senderId;
  final String? senderDisplayName;
  final int tsMs;
  final bool isOwn;
  final bool utd;
  final String? msgtype;
  final String? filename;
  final String? mimeType;
  final int? width;
  final int? height;
  final int? durationMs;

  String get senderLabel => senderDisplayName ?? senderId;

  bool get isImage => msgtype == 'm.image';

  bool get isVideo => msgtype == 'm.video';

  bool get isMedia => isImage || isVideo;

  /// User-written caption for media, if any (excludes filename placeholder bodies).
  String? get mediaCaption {
    if (!isMedia) {
      return null;
    }
    final fname = filename;
    if (fname != null && body == '[$fname]') {
      return null;
    }
    if (body.startsWith('[') && body.endsWith(']')) {
      return null;
    }
    return body;
  }
}
