import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/family_api.dart';
import '../api/models.dart';
import 'caldav_client.dart';
import 'ics.dart';

class CalendarEventView {
  CalendarEventView({
    required this.object,
    required this.calendar,
    required this.isOrganizer,
    required this.myPartStat,
    required this.needsMyResponse,
  });

  final CalDavEventObject object;
  final CalDavCalendar calendar;
  final bool isOrganizer;
  final String? myPartStat;
  final bool needsMyResponse;

  IcsEvent get event => object.event;
}

class CalendarService {
  CalendarService({
    required this._bundle,
    http.Client? httpClient,
    FamilyApiClient? familyApi,
  })  : _client = httpClient,
        _familyApi = familyApi ?? FamilyApiClient(client: httpClient),
        _ownsApi = familyApi == null;

  final EnrollmentBundle _bundle;
  final http.Client? _client;
  final FamilyApiClient _familyApi;
  final bool _ownsApi;

  CalDavClient? _caldav;
  bool _ownsCalDav = false;

  CalDavCredentials? get credentials => _bundle.caldavCredentials;

  String familyMemberEmail(String username) =>
      '$username@${_bundle.serverName}';

  CalDavClient _openCalDav() {
    final creds = credentials;
    if (creds == null || !creds.isConfigured) {
      throw CalDavException('Calendar credentials missing — enroll again on this device');
    }
    if (_caldav != null) {
      return _caldav!;
    }
    if (_client != null) {
      _caldav = CalDavClient.withClient(
        root: creds.root,
        username: creds.username,
        password: creds.password,
        client: _client,
      );
      _ownsCalDav = false;
    } else {
      _caldav = CalDavClient(
        root: creds.root,
        username: creds.username,
        password: creds.password,
      );
      _ownsCalDav = true;
    }
    return _caldav!;
  }

  Future<List<CalDavCalendar>> listCalendars() async {
    return _openCalDav().listCalendars();
  }

  Future<List<CalendarEventView>> loadUpcoming({
    Duration horizon = const Duration(days: 90),
    int pastDays = 7,
  }) async {
    final client = _openCalDav();
    final calendars = await client.listCalendars();
    final now = DateTime.now().toUtc();
    final start = now.subtract(Duration(days: pastDays));
    final end = now.add(horizon);
    final myEmail = familyMemberEmail(_bundle.username).toLowerCase();
    final views = <CalendarEventView>[];
    for (final cal in calendars) {
      final objects = await client.queryEvents(cal, rangeStart: start, rangeEnd: end);
      for (final obj in objects) {
        views.add(_wrapEvent(obj, cal, myEmail));
      }
    }
    views.sort((a, b) {
      final as = a.event.dtStart ?? DateTime.utc(1970);
      final bs = b.event.dtStart ?? DateTime.utc(1970);
      return as.compareTo(bs);
    });
    return views;
  }

  CalendarEventView _wrapEvent(
    CalDavEventObject obj,
    CalDavCalendar cal,
    String myEmail,
  ) {
    final org = obj.event.organizerEmail?.toLowerCase();
    final isOrganizer = org == myEmail || org == _bundle.username.toLowerCase();
    final att = obj.event.attendeeForEmail(myEmail);
    final partStat = att?.partStat;
    final needsResponse = att != null && partStat == 'NEEDS-ACTION' && !isOrganizer;
    return CalendarEventView(
      object: obj,
      calendar: cal,
      isOrganizer: isOrganizer,
      myPartStat: partStat,
      needsMyResponse: needsResponse,
    );
  }

  Future<CalDavEventObject> createEvent({
    required CalDavCalendar calendar,
    required String title,
    required DateTime start,
    required DateTime end,
    required bool allDay,
    String location = '',
    String notes = '',
    List<FamilyMember> attendees = const [],
  }) async {
    final uid = _newUid();
    final organizerEmail = familyMemberEmail(_bundle.username);
    final attendeeList = attendees
        .where((m) => m.username != _bundle.username)
        .map(
          (m) => IcsAttendee(
            email: familyMemberEmail(m.username),
            cn: m.displayName ?? m.username,
            partStat: 'NEEDS-ACTION',
            rsvp: true,
          ),
        )
        .toList();
    final event = IcsEvent(
      uid: uid,
      dtStart: allDay ? _dateOnly(start) : start.toUtc(),
      dtEnd: allDay ? _dateOnly(end) : end.toUtc(),
      allDay: allDay,
      summary: title,
      description: notes,
      location: location,
      organizer: organizerEmail,
      organizerCn: _bundle.username,
      attendees: attendeeList,
      dtStamp: DateTime.now().toUtc(),
    );
    return _openCalDav().putEvent(calendar: calendar, event: event);
  }

  Future<CalDavEventObject> updateEvent({
    required CalendarEventView view,
    required String title,
    required DateTime start,
    required DateTime end,
    required bool allDay,
    String location = '',
    String notes = '',
    List<FamilyMember> attendees = const [],
  }) async {
    final organizerEmail = view.event.organizerEmail ?? familyMemberEmail(_bundle.username);
    final attendeeList = attendees
        .where((m) => m.username != _bundle.username)
        .map((m) {
      final existing = view.event.attendeeForEmail(familyMemberEmail(m.username));
      return IcsAttendee(
        email: familyMemberEmail(m.username),
        cn: m.displayName ?? m.username,
        partStat: existing?.partStat ?? 'NEEDS-ACTION',
        rsvp: true,
      );
    }).toList();
    final updated = view.event.copyWith(
      summary: title,
      description: notes,
      location: location,
      dtStart: allDay ? _dateOnly(start) : start.toUtc(),
      dtEnd: allDay ? _dateOnly(end) : end.toUtc(),
      allDay: allDay,
      organizer: organizerEmail,
      organizerCn: view.event.organizerCn ?? _bundle.username,
      attendees: attendeeList,
      sequence: view.event.sequence + 1,
      dtStamp: DateTime.now().toUtc(),
    );
    return _openCalDav().putEvent(
      calendar: view.calendar,
      event: updated,
      objectHref: view.object.href,
      etag: view.object.etag,
    );
  }

  Future<CalDavEventObject> respondToInvite(
    CalendarEventView view, {
    required bool accept,
  }) async {
    final myEmail = familyMemberEmail(_bundle.username);
    final partStat = accept ? 'ACCEPTED' : 'DECLINED';
    final attendees = view.event.attendees.map((a) {
      if (_unmailto(a.mailto).toLowerCase() == myEmail.toLowerCase()) {
        return IcsAttendee(
          email: a.email,
          partStat: partStat,
          rsvp: a.rsvp,
          cn: a.cn,
        );
      }
      return a;
    }).toList();
    final updated = view.event.copyWith(
      attendees: attendees,
      sequence: view.event.sequence + 1,
      dtStamp: DateTime.now().toUtc(),
    );
    return _openCalDav().putEvent(
      calendar: view.calendar,
      event: updated,
      objectHref: view.object.href,
      etag: view.object.etag,
    );
  }

  Future<void> deleteEvent(CalendarEventView view) async {
    await _openCalDav().deleteEvent(
      href: view.object.href,
      etag: view.object.etag,
    );
  }

  Future<List<FamilyMember>> fetchFamilyMembers() {
    return _familyApi.fetchMembers(_bundle);
  }

  void dispose() {
    if (_ownsCalDav) {
      _caldav?.close();
    }
    if (_ownsApi) {
      _familyApi.close();
    }
  }

  String _newUid() {
    final r = Random.secure();
    final hex = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return 'tinyweb-$hex@${_bundle.serverName}';
  }

  DateTime _dateOnly(DateTime dt) =>
      DateTime.utc(dt.year, dt.month, dt.day);

  String _unmailto(String v) {
    final lower = v.toLowerCase();
    if (lower.startsWith('mailto:')) {
      return v.substring(7);
    }
    return v;
  }
}
