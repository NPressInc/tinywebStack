import 'dart:convert';

import 'package:http/http.dart' as http;

class MobilizonException implements Exception {
  MobilizonException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MobilizonClient {
  MobilizonClient({
    required String apiUrl,
    required this.accessToken,
    http.Client? client,
  })  : _apiUrl = apiUrl.replaceAll(RegExp(r'/+$'), ''),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final String _apiUrl;
  final String accessToken;
  final http.Client _client;
  final bool _ownsClient;

  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<Map<String, dynamic>> gql(
    String query, {
    Map<String, dynamic>? variables,
  }) async {
    final body = <String, dynamic>{'query': query};
    if (variables != null) {
      body['variables'] = variables;
    }
    final response = await _client.post(
      Uri.parse(_apiUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MobilizonException(
        'Mobilizon API HTTP ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final errors = decoded['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      final msg = first is Map ? (first['message'] as String?) : null;
      throw MobilizonException(msg ?? 'Mobilizon GraphQL error');
    }
    return (decoded['data'] as Map<String, dynamic>?) ?? {};
  }
}
