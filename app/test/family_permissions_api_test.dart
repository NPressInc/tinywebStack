import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      dashboardBase: '/family',
      enrollUrl: '/family/api/app/enroll',
    );

EnrollmentBundle _parentBundle() => EnrollmentBundle(
      deviceId: 'd',
      username: 'parent1',
      role: 'parent',
      mxid: '@parent1:family.example',
      serverName: 'family.example',
      dashboardToken: 'parent-token',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: _discovery(),
    );

void main() {
  test('fetchKidPermissions uses dashboard mount', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/family/permissions/kid1');
      expect(request.headers['Authorization'], 'Bearer parent-token');
      return http.Response(
        jsonEncode({
          'username': 'kid1',
          'mxid': '@kid1:family.example',
          'role': 'kid',
          'events_enabled': true,
          'allowlist_mxids': [],
          'allowlist_domains': [],
          'quiet_hours': null,
        }),
        200,
      );
    });
    final api = FamilyApiClient(client: client);
    final perms = await api.fetchKidPermissions(_parentBundle(), 'kid1');
    expect(perms.username, 'kid1');
    expect(perms.eventsEnabled, isTrue);
    api.close();
  });

  test('updateKidPermissions sends PUT body', () async {
    final client = MockClient((request) async {
      expect(request.method, 'PUT');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['events_enabled'], false);
      return http.Response(
        jsonEncode({
          'username': 'kid1',
          'mxid': '@kid1:family.example',
          'role': 'kid',
          'events_enabled': false,
          'allowlist_mxids': [],
          'allowlist_domains': [],
          'quiet_hours': null,
        }),
        200,
      );
    });
    final api = FamilyApiClient(client: client);
    final perms = await api.updateKidPermissions(
      _parentBundle(),
      'kid1',
      {'events_enabled': false},
    );
    expect(perms.eventsEnabled, isFalse);
    api.close();
  });

  test('fetchFederationPeers', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/family/api/federation');
      return http.Response(
        jsonEncode({
          'trusted_domains': ['family-b.example'],
          'peer_nodes': [
            {'name': 'family-b', 'domain': 'family-b.example'},
          ],
        }),
        200,
      );
    });
    final api = FamilyApiClient(client: client);
    final peers = await api.fetchFederationPeers(_parentBundle());
    expect(peers.trustedDomains, ['family-b.example']);
    expect(peers.peerNodes.first.domain, 'family-b.example');
    api.close();
  });
}
