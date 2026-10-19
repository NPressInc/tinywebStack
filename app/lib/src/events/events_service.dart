import 'package:http/http.dart' as http;

import '../api/models.dart';
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

class EventsService {
  EventsService({
    required this._bundle,
    http.Client? httpClient,
  })  : _httpClient = httpClient,
        _ownsHttp = httpClient == null;

  final EnrollmentBundle _bundle;
  final http.Client? _httpClient;
  final bool _ownsHttp;

  MobilizonClient? _client;
  String? _defaultActorId;

  MobilizonCredentials? get credentials => _bundle.mobilizonCredentials;

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
      client: _httpClient,
    );
    return _client!;
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
