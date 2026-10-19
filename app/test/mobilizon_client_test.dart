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
}
