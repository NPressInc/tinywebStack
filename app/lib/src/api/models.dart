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
      appApiVersion: json['app_api_version'] as String?,
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
      rawJson: json,
    );
  }
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
