class ChatReaction {
  ChatReaction({
    required this.emoji,
    required this.userId,
    required this.reactionEventId,
  });

  final String emoji;
  final String userId;
  final String reactionEventId;
}

class ChatReplyPreview {
  ChatReplyPreview({
    required this.eventId,
    required this.senderId,
    this.senderDisplayName,
    required this.body,
  });

  final String eventId;
  final String senderId;
  final String? senderDisplayName;
  final String body;

  String get senderLabel => senderDisplayName ?? senderId;
}

class ChatUrlPreview {
  ChatUrlPreview({
    required this.url,
    this.title,
    this.description,
    this.imageMxc,
    this.siteName,
  });

  final String url;
  final String? title;
  final String? description;
  final String? imageMxc;
  final String? siteName;
}

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
    this.reactions = const [],
    this.inReplyTo,
    this.sendFailed = false,
    this.localMediaPath,
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
  final List<ChatReaction> reactions;
  final ChatReplyPreview? inReplyTo;
  final bool sendFailed;
  final String? localMediaPath;

  String get senderLabel => senderDisplayName ?? senderId;

  ChatMessage copyWith({
    List<ChatReaction>? reactions,
    ChatReplyPreview? inReplyTo,
    bool? sendFailed,
    String? localMediaPath,
  }) {
    return ChatMessage(
      eventId: eventId,
      body: body,
      senderId: senderId,
      senderDisplayName: senderDisplayName,
      tsMs: tsMs,
      isOwn: isOwn,
      utd: utd,
      msgtype: msgtype,
      filename: filename,
      mimeType: mimeType,
      width: width,
      height: height,
      durationMs: durationMs,
      reactions: reactions ?? this.reactions,
      inReplyTo: inReplyTo ?? this.inReplyTo,
      sendFailed: sendFailed ?? this.sendFailed,
      localMediaPath: localMediaPath ?? this.localMediaPath,
    );
  }

  /// First http(s) URL in plain text bodies.
  String? get firstUrl {
    if (isMedia || utd) {
      return null;
    }
    final match = RegExp(r'https?://[^\s<>\]]+').firstMatch(body);
    return match?.group(0);
  }

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
