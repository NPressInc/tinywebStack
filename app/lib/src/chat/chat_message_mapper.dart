import '../rust/api/matrix.dart' as rust;
import 'chat_models.dart';

ChatReaction chatReactionFromRust(rust.MessageReaction r) {
  return ChatReaction(
    emoji: r.emoji,
    userId: r.userId,
    reactionEventId: r.reactionEventId,
  );
}

ChatReplyPreview? chatReplyFromRust(rust.ReplyPreview? r) {
  if (r == null) {
    return null;
  }
  return ChatReplyPreview(
    eventId: r.eventId,
    senderId: r.sender,
    senderDisplayName: r.senderDisplayName,
    body: r.body,
  );
}

ChatUrlPreview chatUrlPreviewFromRust(rust.UrlPreview p) {
  return ChatUrlPreview(
    url: p.url,
    title: p.title,
    description: p.description,
    imageMxc: p.imageMxc,
    siteName: p.siteName,
  );
}

ChatMessage chatMessageFromTimeline(rust.TimelineMessage m) {
  return ChatMessage(
    eventId: m.eventId,
    body: m.body,
    senderId: m.sender,
    senderDisplayName: m.senderDisplayName,
    tsMs: m.tsMs.toInt(),
    isOwn: m.isOwn,
    utd: m.utd,
    msgtype: m.msgtype,
    filename: m.filename,
    mimeType: m.mimeType,
    width: m.width,
    height: m.height,
    durationMs: m.durationMs?.toInt(),
    reactions: m.reactions.map(chatReactionFromRust).toList(),
    inReplyTo: chatReplyFromRust(m.inReplyTo),
  );
}

ChatMessage chatMessageFromIncoming(rust.IncomingMessage m) {
  return ChatMessage(
    eventId: m.eventId,
    body: m.body,
    senderId: m.sender,
    senderDisplayName: m.senderDisplayName,
    tsMs: m.tsMs.toInt(),
    isOwn: m.isOwn,
    utd: m.utd,
    msgtype: m.msgtype,
    filename: m.filename,
    mimeType: m.mimeType,
    width: m.width,
    height: m.height,
    durationMs: m.durationMs?.toInt(),
    reactions: m.reactions.map(chatReactionFromRust).toList(),
    inReplyTo: chatReplyFromRust(m.inReplyTo),
  );
}
