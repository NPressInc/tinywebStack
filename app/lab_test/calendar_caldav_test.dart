import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/api/tls_http_client.dart';
import 'package:tinyweb/src/calendar/caldav_client.dart';
import 'package:tinyweb/src/calendar/calendar_service.dart';

void main() {
  final origin = Platform.environment['TW_HS'];
  if (origin == null || origin.isEmpty) {
    test(
      'calendar caldav e2e (skipped — set TW_HS)',
      () {},
      skip: 'TW_HS not set',
    );
    return;
  }

  test('parent creates event on tws-family; kid accepts invite', () async {
    final password = Platform.environment['TW_TEST_PASSWORD'];
    if (password == null || password.isEmpty) {
      fail('TW_TEST_PASSWORD must be set');
    }
    final parentUser = Platform.environment['TW_PARENT_USER'] ?? 'parent';
    final kidUser = Platform.environment['TW_KID_USER'] ?? 'kid';
    final httpClient = tlsHttpClientFromEnvironment();
    final discovery = await DiscoveryClient(client: httpClient).fetch(origin);
    final api = FamilyApiClient(client: httpClient);

    final parentBundle = await api.enroll(
      discovery: discovery,
      method: 'password',
      username: parentUser,
      password: password,
      deviceName: 'tw_calendar_lab_parent',
    );
    final kidBundle = await api.enroll(
      discovery: discovery,
      method: 'password',
      username: kidUser,
      password: password,
      deviceName: 'tw_calendar_lab_kid',
    );
    expect(parentBundle.caldavCredentials, isNotNull);
    expect(kidBundle.caldavCredentials, isNotNull);

    final parentService = CalendarService(
      bundle: parentBundle,
      httpClient: httpClient,
      familyApi: api,
    );
    final kidService = CalendarService(
      bundle: kidBundle,
      httpClient: httpClient,
      familyApi: api,
    );

    final cals = await parentService.listCalendars();
    final familyCal = cals.firstWhere(
      (c) => c.calendarId == 'tws-family',
      orElse: () => throw StateError('tws-family calendar missing'),
    );

    final start = DateTime.now().toUtc().add(const Duration(days: 3));
    final end = start.add(const Duration(hours: 1));
    final members = await parentService.fetchFamilyMembers();
    final kidMember = members.firstWhere((m) => m.username == kidUser);

    final created = await parentService.createEvent(
      calendar: familyCal,
      title: 'TinyWeb lab calendar test',
      start: start,
      end: end,
      allDay: false,
      attendees: [kidMember],
    );
    final uid = created.event.uid;

    CalendarEventView? kidView;
    for (var i = 0; i < 20; i++) {
      final events = await kidService.loadUpcoming(pastDays: 0);
      kidView = events.cast<CalendarEventView?>().firstWhere(
            (v) => v?.event.uid == uid,
            orElse: () => null,
          );
      if (kidView != null) {
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(kidView, isNotNull, reason: 'kid should see invited event');
    kidView = kidView!;
    expect(kidView.needsMyResponse, isTrue);
    await kidService.respondToInvite(kidView, accept: true);

    CalDavEventObject? parentCopy;
    for (var i = 0; i < 25; i++) {
      final events = await parentService.loadUpcoming(pastDays: 0);
      final view = events.cast<CalendarEventView?>().firstWhere(
            (v) => v?.event.uid == uid,
            orElse: () => null,
          );
      if (view != null) {
        final att = view.event.attendeeForEmail(
          parentService.familyMemberEmail(kidUser),
        );
        if (att?.partStat == 'ACCEPTED') {
          parentCopy = view.object;
          break;
        }
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(parentCopy, isNotNull, reason: 'organizer should see ACCEPTED');

    await parentService.deleteEvent(
      (await parentService.loadUpcoming(pastDays: 0))
          .firstWhere((v) => v.event.uid == uid),
    );

    parentService.dispose();
    kidService.dispose();
  });
}
