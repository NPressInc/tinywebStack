import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/api/tls_http_client.dart';
import 'package:tinyweb/src/events/events_models.dart';
import 'package:tinyweb/src/events/events_service.dart';

import 'lab_env.dart';

void main() {
  installLabTestHttpOverrides();
  final origin = Platform.environment['TW_HS'];
  if (origin == null || origin.isEmpty) {
    test(
      'events mobilizon e2e (skipped — set TW_HS)',
      () {},
      skip: 'TW_HS not set',
    );
    return;
  }

  test('parent creates event; kid RSVPs on lab box', () async {
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
      deviceName: 'tw_events_lab_parent',
    );
    final kidBundle = await api.enroll(
      discovery: discovery,
      method: 'password',
      username: kidUser,
      password: password,
      deviceName: 'tw_events_lab_kid',
    );
    expect(parentBundle.mobilizonCredentials, isNotNull);
    expect(kidBundle.mobilizonCredentials, isNotNull);

    final parentService = EventsService(
      bundle: parentBundle,
      httpClient: httpClient,
    );
    final kidService = EventsService(
      bundle: kidBundle,
      httpClient: httpClient,
    );

    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final title = 'TinyWeb lab event $stamp';
    final start = DateTime.now().toUtc().add(const Duration(days: 3));
    final end = start.add(const Duration(hours: 2));
    final created = await parentService.createEvent(
      title: title,
      beginsOn: start,
      endsOn: end,
      description: 'Lab Mobilizon RSVP test',
      location: 'Community hall',
    );
    expect(created.id, isNotEmpty);

    MobilizonEventSummary? found;
    for (var attempt = 0; attempt < 8; attempt++) {
      final list = await kidService.loadUpcoming(limit: 60);
      for (final e in list) {
        if (e.title == title) {
          found = e;
          break;
        }
      }
      if (found != null) {
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    expect(found, isNotNull, reason: 'kid should see parent event on same box');

    final joined = await kidService.join(found!);
    expect(joined.isJoined, isTrue);
    parentService.dispose();
    kidService.dispose();
  });
}
