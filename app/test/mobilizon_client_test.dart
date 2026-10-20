import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tinyweb/src/events/mobilizon_client.dart';

void main() {
  test('gql returns data payload', () async {
    final client = MobilizonClient(
      apiUrl: 'https://mobilizon.example/api',
      accessToken: 'tok',
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer tok');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['query'], contains('searchEvents'));
        return http.Response(
          jsonEncode({
            'data': {
              'searchEvents': {
                'total': 1,
                'elements': [
                  {'id': '1', 'uuid': 'u', 'title': 'Picnic'},
                ],
              },
            },
          }),
          200,
        );
      }),
    );
    final data = await client.gql('query { searchEvents { total } }');
    expect(data['searchEvents'], isNotNull);
    client.dispose();
  });

  test('gql throws on GraphQL errors', () async {
    final client = MobilizonClient(
      apiUrl: 'https://mobilizon.example/api',
      accessToken: 'tok',
      client: MockClient((_) async => http.Response(
            jsonEncode({'errors': [{'message': 'nope'}]}),
            200,
          )),
    );
    expect(
      () => client.gql('query {}'),
      throwsA(isA<MobilizonException>()),
    );
    client.dispose();
  });

  test('401 refreshes token and retries original request', () async {
    var calls = 0;
    String? persistedAccess;
    final client = MobilizonClient(
      apiUrl: 'https://mobilizon.example/api',
      accessToken: 'expired',
      refreshToken: 'refresh-me',
      onTokensRefreshed: (access, refresh) async {
        persistedAccess = access;
        expect(refresh, 'new-refresh');
      },
      client: MockClient((request) async {
        calls++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final query = body['query'] as String;
        if (query.contains('refreshToken')) {
          expect(request.headers.containsKey('Authorization'), isFalse);
          expect(body['variables'], {'refreshToken': 'refresh-me'});
          return http.Response(
            jsonEncode({
              'data': {
                'refreshToken': {
                  'accessToken': 'new-access',
                  'refreshToken': 'new-refresh',
                },
              },
            }),
            200,
          );
        }
        if (calls == 1) {
          expect(request.headers['Authorization'], 'Bearer expired');
          return http.Response('unauthorized', 401);
        }
        expect(request.headers['Authorization'], 'Bearer new-access');
        return http.Response(
          jsonEncode({
            'data': {'searchEvents': {'total': 0}},
          }),
          200,
        );
      }),
    );
    final data = await client.gql('query { searchEvents { total } }');
    expect(data['searchEvents'], isNotNull);
    expect(calls, 3);
    expect(client.accessToken, 'new-access');
    expect(persistedAccess, 'new-access');
    client.dispose();
  });

  test('refresh failure surfaces session expired message', () async {
    final client = MobilizonClient(
      apiUrl: 'https://mobilizon.example/api',
      accessToken: 'expired',
      refreshToken: 'bad-refresh',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final query = body['query'] as String;
        if (query.contains('refreshToken')) {
          return http.Response(
            jsonEncode({
              'errors': [
                {'message': 'invalid refresh token'},
              ],
            }),
            200,
          );
        }
        return http.Response('', 401);
      }),
    );
    expect(
      () => client.gql('query { loggedUser { id } }'),
      throwsA(
        predicate<MobilizonException>(
          (e) => e.message == mobilizonSessionExpiredMessage,
        ),
      ),
    );
    client.dispose();
  });

  test('concurrent 401 waits on single refresh', () async {
    var refreshCalls = 0;
    var apiCalls = 0;
    final client = MobilizonClient(
      apiUrl: 'https://mobilizon.example/api',
      accessToken: 'expired',
      refreshToken: 'rt',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final query = body['query'] as String;
        if (query.contains('refreshToken')) {
          refreshCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return http.Response(
            jsonEncode({
              'data': {
                'refreshToken': {
                  'accessToken': 'fresh',
                  'refreshToken': 'rt2',
                },
              },
            }),
            200,
          );
        }
        apiCalls++;
        final auth = request.headers['Authorization'];
        if (auth == 'Bearer expired') {
          return http.Response('', 401);
        }
        return http.Response(
          jsonEncode({'data': {'ok': apiCalls}}),
          200,
        );
      }),
    );
    final results = await Future.wait([
      client.gql('query { a }'),
      client.gql('query { b }'),
    ]);
    expect(refreshCalls, 1);
    expect(results.length, 2);
    client.dispose();
  });
}
