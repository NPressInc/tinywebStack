// JSON models for family discovery, enrollment, and /app/me.

class FamilyDiscovery {
  FamilyDiscovery({
    required this.serverOrigin,
    this.serverName,
    this.matrixServer,
    this.appApiVersion,
    this.dashboardBase = '/family',
    this.enrollUrl,
    this.matrixHomeserverUrl,
    this.caldavRoot,
    this.eventsUrl,
    this.locationUrl,
  });

  final String serverOrigin;
  final String? serverName;
  final String? matrixServer;
  final String? appApiVersion;
  final String dashboardBase;
  final String? enrollUrl;
  final String? matrixHomeserverUrl;
  final String? caldavRoot;
  final String? eventsUrl;
  final String? locationUrl;

  bool get hasEnrollUrl => enrollUrl != null && enrollUrl!.isNotEmpty;

  String resolveEnrollEndpoint() {
    final path = enrollUrl!;
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    final base = serverOrigin.endsWith('/')
        ? serverOrigin.substring(0, serverOrigin.length - 1)
        : serverOrigin;
    if (path.startsWith('/')) {
      return '$base$path';
    }
    return '$base/$path';
  }

  factory FamilyDiscovery.fromJson(Map<String, dynamic> json, String serverOrigin) {
    return FamilyDiscovery(
      serverOrigin: serverOrigin,
      serverName: json['server_name'] as String?,
      matrixServer: json['matrix_server'] as String?,
      appApiVersion: json['app_api_version']?.toString(),
      dashboardBase: json['dashboard_base'] as String? ?? '/family',
      enrollUrl: json['enroll_url'] as String?,
      matrixHomeserverUrl: json['matrix_homeserver_url'] as String?,
      caldavRoot: json['caldav_root'] as String?,
      eventsUrl: json['events_url'] as String?,
      locationUrl: json['location_url'] as String?,
    );
  }
}

class MatrixEnrollment {
  MatrixEnrollment({
    required this.isOk,
    this.accessToken,
    this.deviceId,
    this.userId,
    this.homeserver,
  });

  final bool isOk;
  final String? accessToken;
  final String? deviceId;
  final String? userId;
  final String? homeserver;
}

extension EnrollmentBundleMatrix on EnrollmentBundle {
  MatrixEnrollment get matrixEnrollment {
    final matrix = rawJson?['matrix'] as Map<String, dynamic>?;
    final status = matrix?['status'] as String?;
    return MatrixEnrollment(
      isOk: status == 'ok',
      accessToken: matrix?['access_token'] as String?,
      deviceId: matrix?['device_id'] as String?,
      userId: matrix?['user_id'] as String? ?? mxid,
      homeserver: matrix?['homeserver'] as String? ??
          matrix?['homeserver_url'] as String? ??
          matrixHomeserverUrl ??
          discovery.matrixHomeserverUrl,
    );
  }
}

class CalDavCredentials {
  CalDavCredentials({
    required this.root,
    required this.username,
    required this.password,
  });

  final String root;
  final String username;
  final String password;

  bool get isConfigured =>
      root.isNotEmpty && username.isNotEmpty && password.isNotEmpty;

  factory CalDavCredentials.fromJson(Map<String, dynamic> json) {
    return CalDavCredentials(
      root: json['root'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'root': root,
        'username': username,
        'password': password,
      };

  static CalDavCredentials? fromEnrollment(EnrollmentBundle bundle) {
    final raw = bundle.rawJson?['caldav'];
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    if (raw['status'] == 'unavailable') {
      return null;
    }
    final creds = CalDavCredentials.fromJson(raw);
    return creds.isConfigured ? creds : null;
  }
}

extension EnrollmentBundleCalDav on EnrollmentBundle {
  CalDavCredentials? get caldavCredentials => CalDavCredentials.fromEnrollment(this);
}

class MobilizonCredentials {
  MobilizonCredentials({
    required this.apiUrl,
    required this.accessToken,
    this.refreshToken,
  });

  final String apiUrl;
  final String accessToken;
  final String? refreshToken;

  bool get isConfigured => apiUrl.isNotEmpty && accessToken.isNotEmpty;

  factory MobilizonCredentials.fromJson(Map<String, dynamic> json) {
    return MobilizonCredentials(
      apiUrl: json['api_url'] as String? ?? '',
      accessToken: json['access_token'] as String? ?? '',
      refreshToken: json['refresh_token'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'api_url': apiUrl,
        'access_token': accessToken,
        if (refreshToken != null) 'refresh_token': refreshToken,
      };

  static MobilizonCredentials? fromEnrollment(EnrollmentBundle bundle) {
    final raw = bundle.rawJson?['mobilizon'];
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    final status = raw['status'] as String?;
    if (status == 'unavailable' ||
        status == 'password_required' ||
        status == 'not_needed') {
      return null;
    }
    if (status != 'ok') {
      return null;
    }
    var apiUrl = raw['api_url'] as String? ?? '';
    final eventsBase = raw['events_url'] as String? ?? bundle.discovery.eventsUrl;
    if (apiUrl.isEmpty && eventsBase != null && eventsBase.isNotEmpty) {
      apiUrl = '${eventsBase.replaceAll(RegExp(r'/+$'), '')}/api';
    }
    final creds = MobilizonCredentials(
      apiUrl: apiUrl,
      accessToken: raw['access_token'] as String? ?? '',
      refreshToken: raw['refresh_token'] as String?,
    );
    return creds.isConfigured ? creds : null;
  }
}

extension EnrollmentBundleMobilizon on EnrollmentBundle {
  MobilizonCredentials? get mobilizonCredentials =>
      MobilizonCredentials.fromEnrollment(this);
}

class OwnTracksCredentials {
  OwnTracksCredentials({
    required this.url,
    required this.username,
    required this.device,
    required this.password,
    required this.tid,
    this.publish = true,
    this.mode = 'http',
  });

  final String url;
  final String username;
  final String device;
  final String password;
  final String tid;
  final bool publish;
  final String mode;

  bool get shouldPublish => publish && mode == 'http' && url.isNotEmpty;

  factory OwnTracksCredentials.fromJson(Map<String, dynamic> json) {
    return OwnTracksCredentials(
      url: json['url'] as String? ?? '',
      username: json['username'] as String? ?? '',
      device: json['device'] as String? ?? '',
      password: json['password'] as String? ?? '',
      tid: json['tid'] as String? ?? '',
      publish: json['publish'] as bool? ?? false,
      mode: json['mode'] as String? ?? 'http',
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'username': username,
        'device': device,
        'password': password,
        'tid': tid,
        'publish': publish,
        'mode': mode,
      };

  static OwnTracksCredentials? fromEnrollment(EnrollmentBundle bundle) {
    final raw = bundle.rawJson?['owntracks'];
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    if (raw['status'] == 'not_needed' || raw['status'] == 'unavailable') {
      return null;
    }
    final creds = OwnTracksCredentials.fromJson(raw);
    return creds.shouldPublish ? creds : null;
  }
}

class EnrollmentBundle {
  EnrollmentBundle({
    required this.deviceId,
    required this.username,
    required this.role,
    required this.mxid,
    required this.serverName,
    required this.dashboardToken,
    required this.apiBase,
    required this.serverOrigin,
    required this.discovery,
    this.matrixHomeserverUrl,
    this.rawJson,
  });

  final String deviceId;
  final String username;
  final String role;
  final String mxid;
  final String serverName;
  final String dashboardToken;
  final String apiBase;
  final String serverOrigin;
  final FamilyDiscovery discovery;
  final String? matrixHomeserverUrl;
  final Map<String, dynamic>? rawJson;

  bool get isParent => role == 'parent';
  bool get isKid => role == 'kid';

  String meUrl(String origin) {
    final base = origin.endsWith('/')
        ? origin.substring(0, origin.length - 1)
        : origin;
    final path = apiBase.startsWith('/') ? apiBase : '/$apiBase';
    return '$base$path/app/me';
  }

  factory EnrollmentBundle.fromJson(
    Map<String, dynamic> json,
    String serverOrigin,
    FamilyDiscovery discovery,
  ) {
    final dashboard = json['dashboard'] as Map<String, dynamic>? ?? {};
    final matrix = json['matrix'] as Map<String, dynamic>?;
    return EnrollmentBundle(
      deviceId: json['device_id'] as String,
      username: json['username'] as String,
      role: json['role'] as String,
      mxid: json['mxid'] as String,
      serverName: json['server_name'] as String? ?? discovery.serverName ?? '',
      dashboardToken: dashboard['token'] as String,
      apiBase: dashboard['api_base'] as String? ?? '/family/api',
      serverOrigin: serverOrigin,
      discovery: discovery,
      matrixHomeserverUrl: matrix?['homeserver'] as String? ??
          matrix?['homeserver_url'] as String? ??
          discovery.matrixHomeserverUrl,
      rawJson: json,
    );
  }

  factory EnrollmentBundle.fromStoredJson(Map<String, dynamic> json) {
    final origin = json['server_origin'] as String;
    final discoveryMap =
        json['discovery'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final discovery = FamilyDiscovery.fromJson(discoveryMap, origin);
    final dashboard = json['dashboard'] as Map<String, dynamic>? ?? {};
    final matrix = json['matrix'] as Map<String, dynamic>?;
    return EnrollmentBundle(
      deviceId: json['device_id'] as String,
      username: json['username'] as String,
      role: json['role'] as String,
      mxid: json['mxid'] as String,
      serverName: json['server_name'] as String? ?? '',
      dashboardToken: dashboard['token'] as String,
      apiBase: dashboard['api_base'] as String? ?? '/family/api',
      serverOrigin: origin,
      discovery: discovery,
      matrixHomeserverUrl: matrix?['homeserver'] as String? ??
          matrix?['homeserver_url'] as String? ??
          discovery.matrixHomeserverUrl,
      rawJson: _storedRawJson(json),
    );
  }

  static Map<String, dynamic>? _storedRawJson(Map<String, dynamic> json) {
    final raw = <String, dynamic>{};
    if (json['matrix'] != null) {
      raw['matrix'] = json['matrix'];
    }
    if (json['owntracks'] != null) {
      raw['owntracks'] = json['owntracks'];
    }
    if (json['caldav'] != null) {
      raw['caldav'] = json['caldav'];
    }
    if (json['mobilizon'] != null) {
      raw['mobilizon'] = json['mobilizon'];
    }
    return raw.isEmpty ? null : raw;
  }

  OwnTracksCredentials? get owntracksCredentials =>
      OwnTracksCredentials.fromEnrollment(this);
}

class QuietHoursInfo {
  QuietHoursInfo({
    required this.configured,
    required this.active,
    this.windowEnd,
    this.timezone,
  });

  final bool configured;
  final bool active;
  final String? windowEnd;
  final String? timezone;

  factory QuietHoursInfo.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return QuietHoursInfo(configured: false, active: false);
    }
    final window = json['window'];
    String? end;
    if (window is Map<String, dynamic>) {
      end = window['end'] as String? ?? window['until'] as String?;
    } else if (window is String) {
      end = window;
    }
    return QuietHoursInfo(
      configured: json['configured'] as bool? ?? false,
      active: json['active'] as bool? ?? false,
      windowEnd: end,
      timezone: json['timezone'] as String?,
    );
  }
}

class FamilyMember {
  FamilyMember({
    required this.username,
    required this.mxid,
    required this.role,
    this.displayName,
  });

  final String username;
  final String mxid;
  final String role;
  final String? displayName;

  factory FamilyMember.fromJson(Map<String, dynamic> json) {
    return FamilyMember(
      username: json['username'] as String? ?? json['user'] as String? ?? '',
      mxid: json['mxid'] as String? ?? json['matrix_id'] as String? ?? '',
      role: json['role'] as String? ?? 'kid',
      displayName: json['display_name'] as String? ?? json['name'] as String?,
    );
  }
}

class KidLocationSnapshot {
  KidLocationSnapshot({
    required this.username,
    required this.displayName,
    this.tid,
    this.lat,
    this.lon,
    this.acc,
    this.batt,
    this.tst,
    this.ageSeconds,
  });

  final String username;
  final String displayName;
  final String? tid;
  final double? lat;
  final double? lon;
  final double? acc;
  final int? batt;
  final int? tst;
  final int? ageSeconds;

  factory KidLocationSnapshot.fromJson(Map<String, dynamic> json) {
    return KidLocationSnapshot(
      username: json['username'] as String? ?? '',
      displayName: json['display_name'] as String? ?? json['username'] as String? ?? '',
      tid: json['tid'] as String?,
      lat: (json['lat'] as num?)?.toDouble(),
      lon: (json['lon'] as num?)?.toDouble(),
      acc: (json['acc'] as num?)?.toDouble(),
      batt: json['batt'] as int?,
      tst: json['tst'] as int?,
      ageSeconds: json['age_seconds'] as int?,
    );
  }
}

class LocationsResponse {
  LocationsResponse({required this.kids, this.status});

  final List<KidLocationSnapshot> kids;
  final String? status;

  factory LocationsResponse.fromJson(Map<String, dynamic> json) {
    final list = json['kids'] as List<dynamic>? ?? [];
    return LocationsResponse(
      kids: list
          .map((e) => KidLocationSnapshot.fromJson(e as Map<String, dynamic>))
          .toList(),
      status: json['status'] as String?,
    );
  }
}

class TrackPoint {
  TrackPoint({this.lat, this.lon, this.acc, this.batt, this.tst, this.tid});

  final double? lat;
  final double? lon;
  final double? acc;
  final int? batt;
  final int? tst;
  final String? tid;

  factory TrackPoint.fromJson(Map<String, dynamic> json) {
    return TrackPoint(
      lat: (json['lat'] as num?)?.toDouble(),
      lon: (json['lon'] as num?)?.toDouble(),
      acc: (json['acc'] as num?)?.toDouble(),
      batt: json['batt'] as int?,
      tst: json['tst'] is int
          ? json['tst'] as int
          : (json['tst'] as num?)?.toInt(),
      tid: json['tid'] as String?,
    );
  }
}

class KidTrackResponse {
  KidTrackResponse({
    required this.username,
    required this.displayName,
    required this.hours,
    required this.points,
    this.status,
  });

  final String username;
  final String displayName;
  final int hours;
  final List<TrackPoint> points;
  final String? status;

  factory KidTrackResponse.fromJson(Map<String, dynamic> json) {
    final list = json['points'] as List<dynamic>? ?? [];
    return KidTrackResponse(
      username: json['username'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      hours: json['hours'] as int? ?? 24,
      points: list
          .map((e) => TrackPoint.fromJson(e as Map<String, dynamic>))
          .toList(),
      status: json['status'] as String?,
    );
  }
}

class QuietHoursConfig {
  QuietHoursConfig({
    required this.start,
    required this.end,
    required this.timezone,
    this.days = const [0, 1, 2, 3, 4, 5, 6],
  });

  final String start;
  final String end;
  final String timezone;
  final List<int> days;

  bool get isConfigured => start.isNotEmpty && end.isNotEmpty;

  factory QuietHoursConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return QuietHoursConfig(start: '', end: '', timezone: 'UTC');
    }
    final daysRaw = json['days'] as List<dynamic>?;
    final days = daysRaw != null
        ? daysRaw.map((d) => (d as num).toInt()).toList()
        : const [0, 1, 2, 3, 4, 5, 6];
    return QuietHoursConfig(
      start: json['start'] as String? ?? '',
      end: json['end'] as String? ?? '',
      timezone: json['timezone'] as String? ?? 'UTC',
      days: days,
    );
  }

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'timezone': timezone,
        'days': days,
      };

  QuietHoursConfig copyWith({
    String? start,
    String? end,
    String? timezone,
    List<int>? days,
  }) {
    return QuietHoursConfig(
      start: start ?? this.start,
      end: end ?? this.end,
      timezone: timezone ?? this.timezone,
      days: days ?? this.days,
    );
  }
}

class KidPermissions {
  KidPermissions({
    required this.mxid,
    required this.username,
    required this.role,
    required this.eventsEnabled,
    required this.allowlistMxids,
    required this.allowlistDomains,
    this.quietHours,
  });

  final String mxid;
  final String username;
  final String role;
  final bool eventsEnabled;
  final List<String> allowlistMxids;
  final List<String> allowlistDomains;
  final QuietHoursConfig? quietHours;

  bool get quietHoursEnabled =>
      quietHours != null && quietHours!.isConfigured;

  factory KidPermissions.fromJson(Map<String, dynamic> json) {
    final qh = json['quiet_hours'];
    return KidPermissions(
      mxid: json['mxid'] as String? ?? '',
      username: json['username'] as String? ?? '',
      role: json['role'] as String? ?? 'kid',
      eventsEnabled: json['events_enabled'] as bool? ?? true,
      allowlistMxids: (json['allowlist_mxids'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      allowlistDomains: (json['allowlist_domains'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      quietHours: qh is Map<String, dynamic>
          ? QuietHoursConfig.fromJson(qh)
          : null,
    );
  }

  KidPermissions copyWith({
    bool? eventsEnabled,
    List<String>? allowlistMxids,
    List<String>? allowlistDomains,
    QuietHoursConfig? quietHours,
    bool clearQuietHours = false,
  }) {
    return KidPermissions(
      mxid: mxid,
      username: username,
      role: role,
      eventsEnabled: eventsEnabled ?? this.eventsEnabled,
      allowlistMxids: allowlistMxids ?? this.allowlistMxids,
      allowlistDomains: allowlistDomains ?? this.allowlistDomains,
      quietHours: clearQuietHours ? null : (quietHours ?? this.quietHours),
    );
  }
}

class FederationPeersResponse {
  FederationPeersResponse({
    required this.trustedDomains,
    required this.peerNodes,
  });

  final List<String> trustedDomains;
  final List<FederationPeerNode> peerNodes;

  factory FederationPeersResponse.fromJson(Map<String, dynamic> json) {
    final peers = json['peer_nodes'] as List<dynamic>? ?? [];
    return FederationPeersResponse(
      trustedDomains: (json['trusted_domains'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      peerNodes: peers
          .map((e) => FederationPeerNode.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class FederationPeerNode {
  FederationPeerNode({required this.name, required this.domain});

  final String name;
  final String domain;

  factory FederationPeerNode.fromJson(Map<String, dynamic> json) {
    return FederationPeerNode(
      name: json['name'] as String? ?? '',
      domain: json['domain'] as String? ?? '',
    );
  }
}

class AppMeProfile {
  AppMeProfile({
    required this.username,
    required this.role,
    required this.mxid,
    required this.quietHours,
    required this.eventsEnabled,
  });

  final String username;
  final String role;
  final String mxid;
  final QuietHoursInfo quietHours;
  final bool eventsEnabled;

  factory AppMeProfile.fromJson(Map<String, dynamic> json) {
    return AppMeProfile(
      username: json['username'] as String,
      role: json['role'] as String,
      mxid: json['mxid'] as String,
      quietHours: QuietHoursInfo.fromJson(
        json['quiet_hours'] as Map<String, dynamic>?,
      ),
      eventsEnabled: json['events_enabled'] as bool? ?? true,
    );
  }
}

enum EnrollErrorKind {
  invalidCredentials,
  notFamilyMember,
  rateLimited,
  network,
  server,
  needsUpdate,
}

class EnrollException implements Exception {
  EnrollException(this.kind, [this.message]);

  final EnrollErrorKind kind;
  final String? message;

  @override
  String toString() => message ?? kind.name;
}
