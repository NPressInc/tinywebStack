import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api/tls_http_client.dart';

class MobilizonException implements Exception {
  MobilizonException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef MobilizonTokensRefreshed = Future<void> Function(
  String accessToken,
  String? refreshToken,
);

const _refreshTokenMutation = r'''
mutation RefreshToken($refreshToken: String!) {
  refreshToken(refreshToken: $refreshToken) {
    accessToken
    refreshToken
  }
}
''';

const mobilizonSessionExpiredMessage =
    'Events sign-in expired — sign out and back in';

class MobilizonClient {
  MobilizonClient({
    required String apiUrl,
    required this.accessToken,
    this.refreshToken,
    this.onTokensRefreshed,
    http.Client? client,
  })  : _apiUrl = apiUrl.replaceAll(RegExp(r'/+$'), ''),
        _client = client ?? defaultTlsHttpClient(),
        _ownsClient = client != null;

  final String _apiUrl;
  String accessToken;
  String? refreshToken;
  final MobilizonTokensRefreshed? onTokensRefreshed;
  final http.Client _client;
  final bool _ownsClient;

  Future<void>? _refreshInFlight;

  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<Map<String, dynamic>> gql(
    String query, {
    Map<String, dynamic>? variables,
  }) async {
    return _gqlWithRetry(query, variables: variables, mayRefresh: true);
  }

  Future<Map<String, dynamic>> _gqlWithRetry(
    String query, {
    Map<String, dynamic>? variables,
    required bool mayRefresh,
  }) async {
    final result = await _postAuthorized(query, variables: variables);
    if (result.authFailure && mayRefresh) {
      await _refreshAccessToken();
      return _gqlWithRetry(query, variables: variables, mayRefresh: false);
    }
    if (result.authFailure) {
      throw MobilizonException(mobilizonSessionExpiredMessage);
    }
    if (result.httpError != null) {
      throw MobilizonException(result.httpError!);
    }
    if (result.graphqlError != null) {
      throw MobilizonException(result.graphqlError!);
    }
    return result.data!;
  }

  Future<_GqlResult> _postAuthorized(
    String query, {
    Map<String, dynamic>? variables,
  }) async {
    final response = await _post(
      query,
      variables: variables,
      bearerToken: accessToken,
    );
    return _parseGqlResponse(response);
  }

  Future<http.Response> _post(
    String query, {
    Map<String, dynamic>? variables,
    String? bearerToken,
  }) async {
    final body = <String, dynamic>{'query': query};
    if (variables != null) {
      body['variables'] = variables;
    }
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (bearerToken != null && bearerToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $bearerToken';
    }
    return _client.post(
      Uri.parse(_apiUrl),
      headers: headers,
      body: jsonEncode(body),
    );
  }

  _GqlResult _parseGqlResponse(http.Response response) {
    if (response.statusCode == 401) {
      return _GqlResult.authFailure();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return _GqlResult.httpError(
        'Mobilizon API HTTP ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final errors = decoded['errors'];
    if (errors is List && errors.isNotEmpty) {
      if (_isAuthGraphQlError(errors)) {
        return _GqlResult.authFailure();
      }
      final first = errors.first;
      final msg = first is Map ? (first['message'] as String?) : null;
      return _GqlResult.graphqlError(msg ?? 'Mobilizon GraphQL error');
    }
    return _GqlResult.ok(
      (decoded['data'] as Map<String, dynamic>?) ?? {},
    );
  }

  bool _isAuthGraphQlError(List<dynamic> errors) {
    for (final err in errors) {
      if (err is! Map) {
        continue;
      }
      final extensions = err['extensions'];
      if (extensions is Map) {
        final code = extensions['code'];
        if (code == 'UNAUTHENTICATED') {
          return true;
        }
      }
      final msg = (err['message'] as String?)?.toLowerCase() ?? '';
      if (msg.contains('unauthenticated') ||
          msg.contains('unauthorized') ||
          msg.contains('not authenticated') ||
          msg.contains('invalid token') ||
          (msg.contains('expired') &&
              (msg.contains('token') || msg.contains('session')))) {
        return true;
      }
    }
    return false;
  }

  Future<void> _refreshAccessToken() async {
    if (_refreshInFlight != null) {
      await _refreshInFlight;
      return;
    }
    final currentRefresh = refreshToken;
    if (currentRefresh == null || currentRefresh.isEmpty) {
      throw MobilizonException(mobilizonSessionExpiredMessage);
    }
    _refreshInFlight = _doRefresh(currentRefresh);
    try {
      await _refreshInFlight;
    } finally {
      _refreshInFlight = null;
    }
  }

  Future<void> _doRefresh(String currentRefresh) async {
    final response = await _post(
      _refreshTokenMutation,
      variables: {'refreshToken': currentRefresh},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MobilizonException(mobilizonSessionExpiredMessage);
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final errors = decoded['errors'];
    if (errors is List && errors.isNotEmpty) {
      throw MobilizonException(mobilizonSessionExpiredMessage);
    }
    final refresh = decoded['data']?['refreshToken'];
    if (refresh is! Map<String, dynamic>) {
      throw MobilizonException(mobilizonSessionExpiredMessage);
    }
    final access = refresh['accessToken'] as String?;
    if (access == null || access.isEmpty) {
      throw MobilizonException(mobilizonSessionExpiredMessage);
    }
    final newRefresh = refresh['refreshToken'] as String?;
    accessToken = access;
    if (newRefresh != null && newRefresh.isNotEmpty) {
      refreshToken = newRefresh;
    }
    await onTokensRefreshed?.call(access, refreshToken);
  }
}

class _GqlResult {
  _GqlResult._({
    this.data,
    this.httpError,
    this.graphqlError,
    this.authFailure = false,
  });

  factory _GqlResult.ok(Map<String, dynamic> data) =>
      _GqlResult._(data: data);

  factory _GqlResult.httpError(String message) =>
      _GqlResult._(httpError: message);

  factory _GqlResult.graphqlError(String message) =>
      _GqlResult._(graphqlError: message);

  factory _GqlResult.authFailure() => _GqlResult._(authFailure: true);

  final Map<String, dynamic>? data;
  final String? httpError;
  final String? graphqlError;
  final bool authFailure;
}
