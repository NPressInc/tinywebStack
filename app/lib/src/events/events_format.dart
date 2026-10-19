String formatMobilizonWhen(DateTime? start, DateTime? end) {
  if (start == null) {
    return 'Time TBD';
  }
  final local = start.toLocal();
  final endLocal = end?.toLocal();
  final startStr =
      '${_dateLabel(local)} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (endLocal == null) {
    return startStr;
  }
  final endStr =
      '${endLocal.hour.toString().padLeft(2, '0')}:${endLocal.minute.toString().padLeft(2, '0')}';
  if (_sameDay(local, endLocal)) {
    return '$startStr – $endStr';
  }
  return '$startStr – ${_dateLabel(endLocal)} $endStr';
}

String _dateLabel(DateTime dt) =>
    '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
