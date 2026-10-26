import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api/models.dart';
import '../api/tls_http_client.dart';
import '../storage/credential_store.dart';
import 'events_models.dart';
import 'mobilizon_client.dart';

const _searchUpcomingQuery = r'''
query SearchUpcoming($beginsOn: DateTime, $limit: Int) {
  searchEvents(beginsOn: $beginsOn, limit: $limit) {
    total
    elements {
      id
      uuid
      title
      beginsOn
      endsOn
      physicalAddress { description locality }
      organizerActor { id name preferredUsername domain }
      attributedTo { id name preferredUsername domain }
      participantStats { going }
      ... on Event {
        description
        visibility
      }
    }
  }
}
''';

const _eventByUuidQuery = r'''
query EventDetail($uuid: UUID!) {
  event(uuid: $uuid) {
    id
    uuid
    title
    description
    beginsOn
    endsOn
    visibility
    physicalAddress { description locality }
    organizerActor { id name preferredUsername domain }
    attributedTo { id name preferredUsername domain }
    participantStats { going }
  }
}
''';

const _loggedUserActorQuery = r'''
query {
  loggedUser {
    id
    defaultActor { id preferredUsername }
  }
}
''';

const _participationQuery = r'''
query EventParticipation($actorId: ID!, $eventId: ID!) {
  person(id: $actorId) {
    participations(eventId: $eventId) {
      elements { id role }
    }
  }
}
''';

const _joinEventMutation = r'''
mutation JoinEvent($eventId: ID!, $actorId: ID!) {
  joinEvent(eventId: $eventId, actorId: $actorId) { id role }
}
''';

const _leaveEventMutation = r'''
mutation LeaveEvent($eventId: ID!, $actorId: ID!) {
  leaveEvent(eventId: $eventId, actorId: $actorId) { id }
}
''';

const _createEventMutation = r'''
mutation CreateEvent(
  $title: String!
  $description: String!
  $begins: DateTime!
  $ends: DateTime!
  $org: ID!
  $vis: EventVisibility!
  $physicalAddress: AddressInput
) {
  createEvent(
    title: $title
    description: $description
    beginsOn: $begins
    endsOn: $ends
    status: CONFIRMED
    visibility: $vis
    organizerActorId: $org
    physicalAddress: $physicalAddress
  ) { id uuid title beginsOn endsOn }
}
''';

const _loginMutation = r'''
mutation Login($email: String!, $password: String!) {
  login(email: $email, password: $password) {
    accessToken
    refreshToken
  }
}
''';

class EventsService {
  EventsService({
    required this._bundle,
    http.Client? httpClient,
    this._credentialStore,
    this._onEnrollmentUpdated,
  })  : _httpClient = httpClient,
        _ownsHttp = httpClient == null;

  EnrollmentBundle _bundle;
  final http.Client? _httpClient;
  final bool _ownsHttp;
  final CredentialStore? _credentialStore;
  final void Function(EnrollmentBundle bundle)? _onEnrollmentUpdated;

  MobilizonClient? _client;
  String? _defaultActorId;

  MobilizonCredentials? get credentials => _bundle.mobilizonCredentials;

  EnrollmentBundle get bundle => _bundle;

  MobilizonClient _openClient() {
    final creds = credentials;
    if (creds == null) {
      throw MobilizonException(
        'Events not available — enroll with your family password to link Mobilizon',
      );
    }
    _client ??= MobilizonClient(
      apiUrl: creds.apiUrl,
      accessToken: creds.accessToken,
      refreshToken: creds.refreshToken,
      onTokensRefreshed: _persistMobilizonTokens,
      client: _httpClient,
    );
    return _client!;
  }

  Future<void> _persistMobilizonTokens(
    String accessToken,
    String? refreshToken,
  ) async {
    _bundle = _bundle.withMobilizonTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
    await _credentialStore?.write(_bundle);
    _onEnrollmentUpdated?.call(_bundle);
  }

  Future<MobilizonCredentials> linkWithPassword(String password) async {
    if (password.trim().isEmpty) {
      throw MobilizonException('Enter your family password');
    }

    final mobRaw = _bundle.rawJson?['mobilizon'];
    final mobMap = mobRaw is Map<String, dynamic> ? mobRaw : null;
    var eventsBase = mobMap?['events_url'] as String? ?? '';
    if (eventsBase.isEmpty) {
      eventsBase = _bundle.discovery.eventsUrl ?? '';
    }
    if (eventsBase.isEmpty && _bundle.serverName.isNotEmpty) {
      eventsBase = 'https://mobilizon.${_bundle.serverName}';
    }
    eventsBase = eventsBase.replaceAll(RegExp(r'/+$'), '');

    final rawApiUrl = mobMap?['api_url'] as String? ?? '';
    final apiUrl = rawApiUrl.isNotEmpty
        ? rawApiUrl
        : (eventsBase.isNotEmpty ? '$eventsBase/api' : '');
    if (apiUrl.isEmpty) {
      throw MobilizonException('Events server URL is not configured');
    }

    final httpClient = _httpClient ?? defaultTlsHttpClient();
    final candidates = _bundle.serverName.isNotEmpty
        ? <String>[
            '${_bundle.username}@${_bundle.serverName}',
            _bundle.username,
          ]
        : <String>[_bundle.username];

    String? lastError;
    for (final email in candidates) {
      final response = await httpClient.post(
        Uri.parse(apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'query': _loginMutation,
          'variables': {'email': email, 'password': password},
        }),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        lastError = 'HTTP ${response.statusCode}';
        continue;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        lastError = 'Invalid response from Events server';
        continue;
      }

      final errors = decoded['errors'] as List<dynamic>?;
      if (errors != null && errors.isNotEmpty) {
        final first = errors.first;
        if (first is Map<String, dynamic>) {
          lastError = first['message'] as String? ?? lastError;
        }
      }

      final data = decoded['data'] as Map<String, dynamic>?;
      final login = data?['login'] as Map<String, dynamic>?;
      final accessToken = login?['accessToken'] as String? ?? '';
      final refreshToken = login?['refreshToken'] as String?;
      if (accessToken.isEmpty) {
        continue;
      }

      final raw = Map<String, dynamic>.from(_bundle.rawJson ?? {});
      raw['mobilizon'] = {
        'status': 'ok',
        if (eventsBase.isNotEmpty) 'events_url': eventsBase,
        'api_url': apiUrl,
        'access_token': accessToken,
        if (refreshToken != null && refreshToken.isNotEmpty)
          'refresh_token': refreshToken,
      };
      _bundle = EnrollmentBundle(
        deviceId: _bundle.deviceId,
        username: _bundle.username,
        role: _bundle.role,
        mxid: _bundle.mxid,
        serverName: _bundle.serverName,
        dashboardToken: _bundle.dashboardToken,
        apiBase: _bundle.apiBase,
        serverOrigin: _bundle.serverOrigin,
        discovery: _bundle.discovery,
        matrixHomeserverUrl: _bundle.matrixHomeserverUrl,
        rawJson: raw,
      );
      _client = null;
      _defaultActorId = null;
      await _credentialStore?.write(_bundle);
      _onEnrollmentUpdated?.call(_bundle);
      return MobilizonCredentials(
        apiUrl: apiUrl,
        accessToken: accessToken,
        refreshToken: refreshToken,
      );
    }

    throw MobilizonException(
      lastError ?? 'Could not sign in to Events — check your family password.',
    );
  }

  Future<String> defaultActorId() async {
    if (_defaultActorId != null) {
      return _defaultActorId!;
    }
    final data = await _openClient().gql(_loggedUserActorQuery);
    final user = data['loggedUser'] as Map<String, dynamic>?;
    final actor = user?['defaultActor'] as Map<String, dynamic>?;
    final id = actor?['id'] as String?;
    if (id == null || id.isEmpty) {
      throw MobilizonException('Mobilizon account has no default profile');
    }
    _defaultActorId = id;
    return id;
  }

  Future<List<MobilizonEventSummary>> loadUpcoming({int limit = 40}) async {
    final client = _openClient();
    final now = DateTime.now().toUtc();
    final data = await client.gql(
      _searchUpcomingQuery,
      variables: {
        'beginsOn': now.toIso8601String(),
        'limit': limit,
      },
    );
    final search = data['searchEvents'] as Map<String, dynamic>?;
    final elements = search?['elements'] as List<dynamic>? ?? [];
    final actorId = await defaultActorId();
    final events = <MobilizonEventSummary>[];
    for (final raw in elements) {
      if (raw is! Map<String, dynamic>) {
        continue;
      }
      var summary = MobilizonEventSummary.fromSearchJson(raw);
      final part = await _participationForEvent(
        client,
        actorId: actorId,
        eventId: summary.id,
      );
      if (part != null) {
        summary = summary.copyWithParticipation(
          participationId: part.id,
          role: part.role,
        );
      }
      events.add(summary);
    }
    events.sort((a, b) {
      final at = a.beginsOn ?? DateTime.utc(9999);
      final bt = b.beginsOn ?? DateTime.utc(9999);
      return at.compareTo(bt);
    });
    return events;
  }

  Future<MobilizonEventSummary> loadEventByUuid(String uuid) async {
    final client = _openClient();
    final data = await client.gql(
      _eventByUuidQuery,
      variables: {'uuid': uuid},
    );
    final ev = data['event'] as Map<String, dynamic>?;
    if (ev == null) {
      throw MobilizonException('Event not found');
    }
    var summary = MobilizonEventSummary.fromSearchJson(ev);
    final actorId = await defaultActorId();
    final part = await _participationForEvent(
      client,
      actorId: actorId,
      eventId: summary.id,
    );
    if (part != null) {
      summary = summary.copyWithParticipation(
        participationId: part.id,
        role: part.role,
      );
    }
    return summary;
  }

  Future<MobilizonEventSummary> join(MobilizonEventSummary event) async {
    final client = _openClient();
    final actorId = await defaultActorId();
    final data = await client.gql(
      _joinEventMutation,
      variables: {'eventId': event.id, 'actorId': actorId},
    );
    final joined = data['joinEvent'] as Map<String, dynamic>?;
    return event.copyWithParticipation(
      participationId: joined?['id'] as String? ?? 'joined',
      role: joined?['role'] as String?,
    );
  }

  Future<MobilizonEventSummary> leave(MobilizonEventSummary event) async {
    final client = _openClient();
    final actorId = await defaultActorId();
    await client.gql(
      _leaveEventMutation,
      variables: {'eventId': event.id, 'actorId': actorId},
    );
    return event.copyWithParticipation(clearParticipation: true);
  }

  Future<MobilizonEventSummary> createEvent({
    required String title,
    required DateTime beginsOn,
    required DateTime endsOn,
    String description = '',
    String? location,
  }) async {
    final client = _openClient();
    final actorId = await defaultActorId();
    final variables = <String, dynamic>{
      'title': title,
      'description': description,
      'begins': beginsOn.toUtc().toIso8601String(),
      'ends': endsOn.toUtc().toIso8601String(),
      'org': actorId,
      'vis': 'PUBLIC',
    };
    if (location != null && location.trim().isNotEmpty) {
      variables['physicalAddress'] = {'description': location.trim()};
    }
    final data = await client.gql(_createEventMutation, variables: variables);
    final created = data['createEvent'] as Map<String, dynamic>?;
    final uuid = created?['uuid'] as String?;
    if (uuid == null || uuid.isEmpty) {
      throw MobilizonException('Create event failed');
    }
    return loadEventByUuid(uuid);
  }

  Future<_Participation?> _participationForEvent(
    MobilizonClient client, {
    required String actorId,
    required String eventId,
  }) async {
    final data = await client.gql(
      _participationQuery,
      variables: {'actorId': actorId, 'eventId': eventId},
    );
    final person = data['person'] as Map<String, dynamic>?;
    final parts = person?['participations'] as Map<String, dynamic>?;
    final elements = parts?['elements'] as List<dynamic>? ?? [];
    if (elements.isEmpty) {
      return null;
    }
    final first = elements.first as Map<String, dynamic>;
    return _Participation(
      id: first['id'] as String? ?? '',
      role: first['role'] as String?,
    );
  }

  void dispose() {
    _client?.dispose();
    if (_ownsHttp && _httpClient != null) {
      _httpClient.close();
    }
  }
}

class _Participation {
  _Participation({required this.id, this.role});

  final String id;
  final String? role;
}
