// Minimal RFC 5545 ICS parse/serialize for VEVENT (CalDAV / Nextcloud).

class IcsAttendee {
  IcsAttendee({
    required this.email,
    this.partStat = 'NEEDS-ACTION',
    this.rsvp = false,
    this.cn,
  });

  final String email;
  final String partStat;
  final bool rsvp;
  final String? cn;

  String get mailto => email.startsWith('mailto:') ? email : 'mailto:$email';
}

class IcsEvent {
  IcsEvent({
    required this.uid,
    this.dtStart,
    this.dtEnd,
    this.allDay = false,
    this.summary = '',
    this.description = '',
    this.location = '',
    this.organizer,
    this.organizerCn,
    this.attendees = const [],
    this.dtStamp,
    this.sequence = 0,
  });

  final String uid;
  final DateTime? dtStart;
  final DateTime? dtEnd;
  final bool allDay;
  final String summary;
  final String description;
  final String location;
  final String? organizer;
  final String? organizerCn;
  final List<IcsAttendee> attendees;
  final DateTime? dtStamp;
  final int sequence;

  String? get organizerEmail {
    final o = organizer;
    if (o == null || o.isEmpty) {
      return null;
    }
    return _unmailto(o);
  }

  IcsAttendee? attendeeForEmail(String email) {
    final norm = email.toLowerCase();
    for (final a in attendees) {
      if (_unmailto(a.mailto).toLowerCase() == norm) {
        return a;
      }
    }
    return null;
  }

  bool get hasPendingInvite {
    for (final a in attendees) {
      if (a.partStat == 'NEEDS-ACTION') {
        return true;
      }
    }
    return false;
  }

  IcsEvent copyWith({
    String? uid,
    DateTime? dtStart,
    DateTime? dtEnd,
    bool? allDay,
    String? summary,
    String? description,
    String? location,
    String? organizer,
    String? organizerCn,
    List<IcsAttendee>? attendees,
    DateTime? dtStamp,
    int? sequence,
  }) {
    return IcsEvent(
      uid: uid ?? this.uid,
      dtStart: dtStart ?? this.dtStart,
      dtEnd: dtEnd ?? this.dtEnd,
      allDay: allDay ?? this.allDay,
      summary: summary ?? this.summary,
      description: description ?? this.description,
      location: location ?? this.location,
      organizer: organizer ?? this.organizer,
      organizerCn: organizerCn ?? this.organizerCn,
      attendees: attendees ?? this.attendees,
      dtStamp: dtStamp ?? this.dtStamp,
      sequence: sequence ?? this.sequence,
    );
  }
}

List<IcsEvent> parseIcsCalendar(String raw) {
  final unfolded = _unfoldLines(raw);
  final events = <IcsEvent>[];
  var inEvent = false;
  var current = <String, List<_IcsProp>>{};

  for (final line in unfolded) {
    if (line == 'BEGIN:VEVENT') {
      inEvent = true;
      current = {};
      continue;
    }
    if (line == 'END:VEVENT') {
      inEvent = false;
      final ev = _eventFromProps(current);
      if (ev != null) {
        events.add(ev);
      }
      continue;
    }
    if (!inEvent) {
      continue;
    }
    final prop = _parseProperty(line);
    if (prop != null) {
      current.putIfAbsent(prop.name, () => []).add(prop);
    }
  }
  return events;
}

IcsEvent? parseIcsEventDocument(String raw) {
  final list = parseIcsCalendar(raw);
  return list.isEmpty ? null : list.first;
}

String serializeIcsEvent(IcsEvent event, {String prodId = '-//TinyWeb//Calendar//EN'}) {
  final buf = StringBuffer();
  buf.writeln('BEGIN:VCALENDAR');
  buf.writeln('VERSION:2.0');
  buf.writeln('PRODID:$prodId');
  buf.writeln('CALSCALE:GREGORIAN');
  buf.writeln('BEGIN:VEVENT');
  buf.writeln('UID:${_escapeText(event.uid)}');
  final stamp = event.dtStamp ?? DateTime.now().toUtc();
  buf.writeln('DTSTAMP:${_formatUtc(stamp)}');
  if (event.allDay) {
    if (event.dtStart != null) {
      buf.writeln('DTSTART;VALUE=DATE:${_formatDate(event.dtStart!)}');
    }
    if (event.dtEnd != null) {
      buf.writeln('DTEND;VALUE=DATE:${_formatDate(event.dtEnd!)}');
    }
  } else {
    if (event.dtStart != null) {
      buf.writeln('DTSTART:${_formatUtc(event.dtStart!)}');
    }
    if (event.dtEnd != null) {
      buf.writeln('DTEND:${_formatUtc(event.dtEnd!)}');
    }
  }
  if (event.summary.isNotEmpty) {
    buf.writeln('SUMMARY:${_escapeText(event.summary)}');
  }
  if (event.description.isNotEmpty) {
    buf.writeln('DESCRIPTION:${_escapeText(event.description)}');
  }
  if (event.location.isNotEmpty) {
    buf.writeln('LOCATION:${_escapeText(event.location)}');
  }
  if (event.organizer != null && event.organizer!.isNotEmpty) {
    final org = event.organizer!.startsWith('mailto:')
        ? event.organizer!
        : 'mailto:${event.organizer}';
    if (event.organizerCn != null && event.organizerCn!.isNotEmpty) {
      buf.writeln('ORGANIZER;CN=${_escapeParam(event.organizerCn!)}:$org');
    } else {
      buf.writeln('ORGANIZER:$org');
    }
  }
  for (final att in event.attendees) {
    final parts = <String>['ATTENDEE'];
    if (att.cn != null && att.cn!.isNotEmpty) {
      parts.add('CN=${_escapeParam(att.cn!)}');
    }
    parts.add('PARTSTAT=${att.partStat}');
    if (att.rsvp) {
      parts.add('RSVP=TRUE');
    }
    buf.writeln('${parts.join(';')}:${att.mailto}');
  }
  if (event.sequence > 0) {
    buf.writeln('SEQUENCE:${event.sequence}');
  }
  buf.writeln('END:VEVENT');
  buf.writeln('END:VCALENDAR');
  return buf.toString();
}

class _IcsProp {
  _IcsProp(this.name, this.params, this.value);

  final String name;
  final Map<String, String> params;
  final String value;
}

List<String> _unfoldLines(String raw) {
  final lines = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final out = <String>[];
  for (final line in lines) {
    if (line.isEmpty) {
      continue;
    }
    if (line.startsWith(' ') || line.startsWith('\t')) {
      if (out.isNotEmpty) {
        out[out.length - 1] = '${out.last}${line.substring(1)}';
      }
    } else {
      out.add(line);
    }
  }
  return out;
}

_IcsProp? _parseProperty(String line) {
  final colon = line.indexOf(':');
  if (colon < 0) {
    return null;
  }
  final head = line.substring(0, colon);
  final value = _unescapeText(line.substring(colon + 1));
  final semi = head.indexOf(';');
  String name;
  final params = <String, String>{};
  if (semi < 0) {
    name = head.toUpperCase();
  } else {
    name = head.substring(0, semi).toUpperCase();
    for (final part in head.substring(semi + 1).split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0) {
        params[part.substring(0, eq).toUpperCase()] =
            _unescapeText(part.substring(eq + 1));
      }
    }
  }
  return _IcsProp(name, params, value);
}

IcsEvent? _eventFromProps(Map<String, List<_IcsProp>> props) {
  final uid = _firstValue(props, 'UID');
  if (uid == null || uid.isEmpty) {
    return null;
  }
  final startProp = _firstProp(props, 'DTSTART');
  final endProp = _firstProp(props, 'DTEND');
  final allDay = startProp?.params['VALUE'] == 'DATE' ||
      (startProp != null && startProp.value.length == 8);
  final dtStart = _parseDateTime(startProp);
  final dtEnd = _parseDateTime(endProp);
  final orgProp = _firstProp(props, 'ORGANIZER');
  final attendees = <IcsAttendee>[];
  for (final p in props['ATTENDEE'] ?? const <_IcsProp>[]) {
    attendees.add(
      IcsAttendee(
        email: p.value,
        partStat: p.params['PARTSTAT'] ?? 'NEEDS-ACTION',
        rsvp: (p.params['RSVP'] ?? '').toUpperCase() == 'TRUE',
        cn: p.params['CN'],
      ),
    );
  }
  final seq = int.tryParse(_firstValue(props, 'SEQUENCE') ?? '0') ?? 0;
  return IcsEvent(
    uid: uid,
    dtStart: dtStart,
    dtEnd: dtEnd,
    allDay: allDay,
    summary: _firstValue(props, 'SUMMARY') ?? '',
    description: _firstValue(props, 'DESCRIPTION') ?? '',
    location: _firstValue(props, 'LOCATION') ?? '',
    organizer: orgProp?.value,
    organizerCn: orgProp?.params['CN'],
    attendees: attendees,
    dtStamp: _parseDateTime(_firstProp(props, 'DTSTAMP')),
    sequence: seq,
  );
}

String? _firstValue(Map<String, List<_IcsProp>> props, String name) {
  final list = props[name];
  if (list == null || list.isEmpty) {
    return null;
  }
  return list.first.value;
}

_IcsProp? _firstProp(Map<String, List<_IcsProp>> props, String name) {
  final list = props[name];
  if (list == null || list.isEmpty) {
    return null;
  }
  return list.first;
}

DateTime? _parseDateTime(_IcsProp? prop) {
  if (prop == null) {
    return null;
  }
  final v = prop.value;
  if (v.length == 8) {
    return DateTime.utc(
      int.parse(v.substring(0, 4)),
      int.parse(v.substring(4, 6)),
      int.parse(v.substring(6, 8)),
    );
  }
  if (v.endsWith('Z')) {
    final core = v.substring(0, v.length - 1);
    if (core.contains('T') && core.length >= 15) {
      return DateTime.utc(
        int.parse(core.substring(0, 4)),
        int.parse(core.substring(4, 6)),
        int.parse(core.substring(6, 8)),
        int.parse(core.substring(9, 11)),
        int.parse(core.substring(11, 13)),
        int.parse(core.substring(13, 15)),
      );
    }
  }
  return DateTime.tryParse(v)?.toUtc();
}

String _formatUtc(DateTime dt) {
  final u = dt.toUtc();
  return '${u.year.toString().padLeft(4, '0')}'
      '${u.month.toString().padLeft(2, '0')}'
      '${u.day.toString().padLeft(2, '0')}T'
      '${u.hour.toString().padLeft(2, '0')}'
      '${u.minute.toString().padLeft(2, '0')}'
      '${u.second.toString().padLeft(2, '0')}Z';
}

String _formatDate(DateTime dt) {
  final u = dt.toUtc();
  return '${u.year.toString().padLeft(4, '0')}'
      '${u.month.toString().padLeft(2, '0')}'
      '${u.day.toString().padLeft(2, '0')}';
}

String _escapeText(String s) =>
    s.replaceAll('\\', '\\\\').replaceAll('\n', '\\n').replaceAll(',', '\\,').replaceAll(';', '\\;');

String _escapeParam(String s) =>
    s.contains(',') || s.contains(';') ? '"$s"' : s;

String _unescapeText(String s) =>
    s.replaceAll('\\n', '\n').replaceAll('\\,', ',').replaceAll('\\;', ';').replaceAll('\\\\', '\\');

String _unmailto(String v) {
  final lower = v.toLowerCase();
  if (lower.startsWith('mailto:')) {
    return v.substring(7);
  }
  return v;
}
