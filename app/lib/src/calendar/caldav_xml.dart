// Small helpers for CalDAV multistatus XML (no external XML dependency).

String localName(String tag) {
  final i = tag.indexOf('}');
  return i >= 0 ? tag.substring(i + 1) : tag;
}

class DavResponse {
  DavResponse({required this.href, this.props = const {}});

  final String href;
  final Map<String, String> props;
}

List<DavResponse> parseMultistatus(String xml) {
  final responses = <DavResponse>[];
  final responseBlocks = _splitTopLevel(xml, 'response');
  for (final block in responseBlocks) {
    final href = _firstElementText(block, 'href');
    if (href == null) {
      continue;
    }
    final propBlock = _findPropstatOkProps(block);
    final props = <String, String>{};
    if (propBlock != null) {
      for (final name in ['displayname', 'getetag', 'calendar-data']) {
        final t = _firstElementText(propBlock, name);
        if (t != null) {
          props[name] = t;
        }
      }
      final rt = _firstElementBlock(propBlock, 'resourcetype');
      if (rt != null) {
        props['resourcetype'] = rt;
      }
    }
    responses.add(DavResponse(href: href.trim(), props: props));
  }
  return responses;
}

bool responseIsCalendar(DavResponse r) {
  final rt = r.props['resourcetype'] ?? '';
  return rt.contains('calendar');
}

List<String> _splitTopLevel(String xml, String local) {
  final out = <String>[];
  final pattern = RegExp(
    '<([\\w:]*:)?$local\\b[^>]*>',
    caseSensitive: false,
  );
  final endPattern = RegExp(
    '</([\\w:]*:)?$local>',
    caseSensitive: false,
  );
  var i = 0;
  while (i < xml.length) {
    final start = pattern.matchAsPrefix(xml, i);
    if (start == null) {
      i++;
      continue;
    }
    final openEnd = start.end;
    final close = endPattern.matchAsPrefix(xml, openEnd);
    if (close != null) {
      out.add(xml.substring(start.start, close.end));
      i = close.end;
      continue;
    }
    final nextClose = endPattern.firstMatch(xml.substring(openEnd));
    if (nextClose == null) {
      break;
    }
    final end = openEnd + nextClose.end;
    out.add(xml.substring(start.start, end));
    i = end;
  }
  return out;
}

String? _findPropstatOkProps(String responseBlock) {
  final propstats = _splitTopLevel(responseBlock, 'propstat');
  for (final ps in propstats) {
    final status = _firstElementText(ps, 'status');
    if (status != null && status.contains('200')) {
      final prop = _firstElementBlock(ps, 'prop');
      if (prop != null) {
        return prop;
      }
    }
  }
  return _firstElementBlock(responseBlock, 'prop');
}

String? _firstElementBlock(String xml, String local) {
  final open = RegExp('<([\\w:]*:)?$local\\b[^>]*>', caseSensitive: false);
  final m = open.firstMatch(xml);
  if (m == null) {
    return null;
  }
  final close = RegExp('</([\\w:]*:)?$local>', caseSensitive: false);
  final c = close.firstMatch(xml.substring(m.end));
  if (c == null) {
    return null;
  }
  return xml.substring(m.start, m.end + c.end);
}

String? _firstElementText(String xml, String local) {
  final block = _firstElementBlock(xml, local);
  if (block == null) {
    return null;
  }
  final open = RegExp('<([\\w:]*:)?$local\\b[^>]*>', caseSensitive: false);
  final m = open.firstMatch(block);
  if (m == null) {
    return null;
  }
  final inner = block.substring(m.end);
  final close = inner.indexOf('<');
  final text = close < 0 ? inner : inner.substring(0, close);
  return text.trim().isEmpty ? null : _decodeXmlText(text.trim());
}

String _decodeXmlText(String s) =>
    s.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&').replaceAll('&quot;', '"');

String calendarQueryBody({
  required DateTime rangeStart,
  required DateTime rangeEnd,
}) {
  final start = _caldavUtc(rangeStart);
  final end = _caldavUtc(rangeEnd);
  return '''<?xml version="1.0" encoding="utf-8"?>
<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:prop>
    <D:getetag/>
    <C:calendar-data/>
  </D:prop>
  <C:filter>
    <C:comp-filter name="VCALENDAR">
      <C:comp-filter name="VEVENT">
        <C:time-range start="$start" end="$end"/>
      </C:comp-filter>
    </C:comp-filter>
  </C:filter>
</C:calendar-query>''';
}

String propfindCalendarsBody() => '''<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:prop>
    <D:displayname/>
    <D:resourcetype/>
  </D:prop>
</D:propfind>''';

String _caldavUtc(DateTime dt) {
  final u = dt.toUtc();
  return '${u.year.toString().padLeft(4, '0')}'
      '${u.month.toString().padLeft(2, '0')}'
      '${u.day.toString().padLeft(2, '0')}T'
      '${u.hour.toString().padLeft(2, '0')}'
      '${u.minute.toString().padLeft(2, '0')}'
      '${u.second.toString().padLeft(2, '0')}Z';
}
