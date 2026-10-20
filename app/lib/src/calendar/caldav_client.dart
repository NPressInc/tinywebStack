import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api/tls_http_client.dart';

import 'caldav_xml.dart';
import 'ics.dart';

class CalDavException implements Exception {
  CalDavException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class CalDavCalendar {
  CalDavCalendar({
    required this.href,
    required this.displayName,
    required this.calendarId,
  });

  final String href;
  final String displayName;
  final String calendarId;
}

class CalDavEventObject {
  CalDavEventObject({
    required this.href,
    required this.etag,
    required this.ics,
    required this.event,
    required this.calendarHref,
  });

  final String href;
  final String etag;
  final String ics;
  final IcsEvent event;
  final String calendarHref;
}

class CalDavClient {
  final String root;
  final String username;
  final String password;
  final http.Client _client;
  final bool _ownsClient;

  CalDavClient({
    required this.root,
    required this.username,
    required this.password,
    http.Client? client,
    bool ownsClient = true,
  })  : _client = client ?? defaultTlsHttpClient(),
        _ownsClient = client != null && ownsClient;

  factory CalDavClient.withClient({
    required String root,
    required String username,
    required String password,
    required http.Client client,
  }) {
    return CalDavClient(
      root: root,
      username: username,
      password: password,
      client: client,
      ownsClient: false,
    );
  }

  String get principalHref =>
      '${root.replaceAll(RegExp(r'/+$'), '')}/principals/users/$username/';

  String get calendarsHome =>
      '${root.replaceAll(RegExp(r'/+$'), '')}/calendars/$username/';

  Map<String, String> _headers({
    String? depth,
    String? contentType,
    String? ifMatch,
  }) {
    final h = <String, String>{
      'Authorization': _basicAuth(),
    };
    if (depth != null) {
      h['Depth'] = depth;
    }
    if (contentType != null) {
      h['Content-Type'] = contentType;
    }
    if (ifMatch != null && ifMatch.isNotEmpty) {
      h['If-Match'] = ifMatch;
    }
    return h;
  }

  String _basicAuth() {
    final token = base64Encode(utf8.encode('$username:$password'));
    return 'Basic $token';
  }

  Future<void> verifyLogin() async {
    final request = http.Request('PROPFIND', Uri.parse(principalHref))
      ..headers.addAll(_headers(depth: '0', contentType: 'application/xml; charset=utf-8'))
      ..body = propfindCalendarsBody();
    final streamed = await _client.send(request);
    await streamed.stream.drain();
    final status = streamed.statusCode;
    if (status == 401 || status == 403) {
      throw CalDavException('CalDAV authentication failed', statusCode: status);
    }
    if (status != 207 && status != 200) {
      throw CalDavException('CalDAV PROPFIND failed ($status)', statusCode: status);
    }
  }

  Future<List<CalDavCalendar>> listCalendars() async {
    final url = calendarsHome;
    final request = http.Request('PROPFIND', Uri.parse(url))
      ..headers.addAll(_headers(depth: '1', contentType: 'application/xml; charset=utf-8'))
      ..body = propfindCalendarsBody();
    final streamed = await _client.send(request);
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode == 401 || streamed.statusCode == 403) {
      throw CalDavException('CalDAV authentication failed', statusCode: streamed.statusCode);
    }
    if (streamed.statusCode != 207) {
      throw CalDavException(
        'Failed to list calendars (${streamed.statusCode})',
        statusCode: streamed.statusCode,
      );
    }
    final responses = parseMultistatus(body);
    final calendars = <CalDavCalendar>[];
    for (final r in responses) {
      if (!responseIsCalendar(r)) {
        continue;
      }
      if (r.href.endsWith('/inbox/') ||
          r.href.endsWith('/outbox/') ||
          r.href.contains('/trashbin/')) {
        continue;
      }
      final id = _calendarIdFromHref(r.href);
      final name = r.props['displayname']?.isNotEmpty == true
          ? r.props['displayname']!
          : _friendlyCalendarName(id);
      calendars.add(
        CalDavCalendar(
          href: _absoluteHref(r.href),
          displayName: name,
          calendarId: id,
        ),
      );
    }
    calendars.sort((a, b) => a.displayName.compareTo(b.displayName));
    return calendars;
  }

  Future<List<CalDavEventObject>> queryEvents(
    CalDavCalendar calendar, {
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) async {
    final request = http.Request('REPORT', Uri.parse(calendar.href))
      ..headers.addAll(_headers(depth: '1', contentType: 'application/xml; charset=utf-8'))
      ..body = calendarQueryBody(rangeStart: rangeStart, rangeEnd: rangeEnd);
    final streamed = await _client.send(request);
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode == 401 || streamed.statusCode == 403) {
      throw CalDavException('CalDAV authentication failed', statusCode: streamed.statusCode);
    }
    if (streamed.statusCode != 207) {
      throw CalDavException(
        'Calendar query failed (${streamed.statusCode})',
        statusCode: streamed.statusCode,
      );
    }
    final responses = parseMultistatus(body);
    final objects = <CalDavEventObject>[];
    for (final r in responses) {
      final data = r.props['calendar-data'];
      if (data == null || data.isEmpty) {
        continue;
      }
      for (final ev in parseIcsCalendar(data)) {
        objects.add(
          CalDavEventObject(
            href: _absoluteHref(r.href),
            etag: _normalizeEtag(r.props['getetag']),
            ics: data,
            event: ev,
            calendarHref: calendar.href,
          ),
        );
      }
    }
    objects.sort((a, b) {
      final as = a.event.dtStart ?? DateTime.utc(1970);
      final bs = b.event.dtStart ?? DateTime.utc(1970);
      return as.compareTo(bs);
    });
    return objects;
  }

  Future<CalDavEventObject> putEvent({
    required CalDavCalendar calendar,
    required IcsEvent event,
    String? objectHref,
    String? etag,
  }) async {
    final uid = event.uid;
    final href = objectHref ?? '${calendar.href}$uid.ics';
    final ics = serializeIcsEvent(event);
    final request = http.Request('PUT', Uri.parse(href))
      ..headers.addAll({
        ..._headers(contentType: 'text/calendar; charset=utf-8'),
        if (etag != null && etag.isNotEmpty) 'If-Match': etag,
      })
      ..body = ics;
    final streamed = await _client.send(request);
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode == 401 || streamed.statusCode == 403) {
      throw CalDavException('CalDAV authentication failed', statusCode: streamed.statusCode);
    }
    if (streamed.statusCode != 201 && streamed.statusCode != 204) {
      throw CalDavException(
        'Failed to save event (${streamed.statusCode})${body.isNotEmpty ? ': $body' : ''}',
        statusCode: streamed.statusCode,
      );
    }
    final newEtag = streamed.headers['etag'] ?? etag ?? '';
    return CalDavEventObject(
      href: href,
      etag: _normalizeEtag(newEtag),
      ics: ics,
      event: event,
      calendarHref: calendar.href,
    );
  }

  Future<void> deleteEvent({
    required String href,
    required String etag,
  }) async {
    final request = http.Request('DELETE', Uri.parse(href))
      ..headers.addAll(_headers(ifMatch: etag));
    final streamed = await _client.send(request);
    await streamed.stream.drain();
    if (streamed.statusCode == 401 || streamed.statusCode == 403) {
      throw CalDavException('CalDAV authentication failed', statusCode: streamed.statusCode);
    }
    if (streamed.statusCode != 204 && streamed.statusCode != 200) {
      throw CalDavException(
        'Failed to delete event (${streamed.statusCode})',
        statusCode: streamed.statusCode,
      );
    }
  }

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  String _absoluteHref(String href) {
    if (href.startsWith('http://') || href.startsWith('https://')) {
      return href;
    }
    final base = Uri.parse(root);
    if (href.startsWith('/')) {
      return '${base.scheme}://${base.host}$href';
    }
    return '${root.replaceAll(RegExp(r'/+$'), '')}/$href';
  }

  String _calendarIdFromHref(String href) {
    final parts = href.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) {
      return href;
    }
    var last = parts.last;
    if (last.isEmpty && parts.length > 1) {
      last = parts[parts.length - 2];
    }
    return last.replaceAll('/', '');
  }

  String _friendlyCalendarName(String id) {
    switch (id) {
      case 'tws-family':
        return 'Family';
      case 'tws-parents':
        return 'Parents';
      case 'tws-kids':
        return 'Kids';
      default:
        if (id.startsWith('personal-')) {
          return 'Personal';
        }
        return id;
    }
  }

  String _normalizeEtag(String? raw) {
    if (raw == null || raw.isEmpty) {
      return '';
    }
    var e = raw.trim();
    if (e.startsWith('"') && e.endsWith('"')) {
      return e;
    }
    return '"$e"';
  }
}
