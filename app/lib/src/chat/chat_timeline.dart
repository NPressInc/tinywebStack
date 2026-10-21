import 'chat_models.dart';

const _groupGapMs = 60 * 1000;
const _dateHeaderGapMs = 60 * 60 * 1000;

sealed class TimelineRow {}

class TimelineDateHeader extends TimelineRow {
  TimelineDateHeader(this.label);

  final String label;
}

class TimelineMessageRow extends TimelineRow {
  TimelineMessageRow({
    required this.message,
    required this.showSenderName,
    required this.isLastInGroup,
    required this.isFirstInGroup,
  });

  final ChatMessage message;
  final bool showSenderName;
  final bool isLastInGroup;
  final bool isFirstInGroup;
}

String formatDateHeader(DateTime dt, DateTime now) {
  final local = dt.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  final h12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final time = '$h12:${local.minute.toString().padLeft(2, '0')} ${local.hour >= 12 ? 'PM' : 'AM'}';
  if (diff == 0) {
    return 'Today $time';
  }
  if (diff == 1) {
    return 'Yesterday';
  }
  if (diff < 7) {
    const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return weekdays[local.weekday - 1];
  }
  return '${local.month}/${local.day}/${local.year}';
}

List<TimelineRow> buildTimelineRows(List<ChatMessage> messages, {bool isGroupRoom = true}) {
  if (messages.isEmpty) {
    return [];
  }
  final now = DateTime.now();
  final rows = <TimelineRow>[];
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    final prev = i > 0 ? messages[i - 1] : null;
    final next = i + 1 < messages.length ? messages[i + 1] : null;

    if (prev == null || m.tsMs - prev.tsMs > _dateHeaderGapMs) {
      rows.add(TimelineDateHeader(formatDateHeader(DateTime.fromMillisecondsSinceEpoch(m.tsMs), now)));
    }

    final sameSenderAsPrev = prev != null &&
        prev.senderId == m.senderId &&
        m.tsMs - prev.tsMs <= _groupGapMs;
    final sameSenderAsNext = next != null &&
        next.senderId == m.senderId &&
        next.tsMs - m.tsMs <= _groupGapMs;

    rows.add(
      TimelineMessageRow(
        message: m,
        showSenderName: isGroupRoom && !m.isOwn && !sameSenderAsPrev,
        isFirstInGroup: !sameSenderAsPrev,
        isLastInGroup: !sameSenderAsNext,
      ),
    );
  }
  return rows;
}
