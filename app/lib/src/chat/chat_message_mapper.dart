import '../rust/api/matrix.dart' as rust;
import 'chat_models.dart';

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
  );
}
