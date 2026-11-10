import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'setup_discovery.dart';
import 'setup_models.dart';

class SetupClient {
  SetupClient({
    required this.baseUri,
    http.Client? client,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Talks to the box by IP while the URL host stays `tinyweb.local`.
  ///
  /// Android allows cleartext for `.local` and does not show a certificate warning
  /// because this hop is plain HTTP on the home network only.
  factory SetupClient.forBox(DiscoveredBox box) {
    return SetupClient(
      baseUri: Uri(scheme: 'http', host: 'tinyweb.local', port: box.port),
      client: lanSetupClient(box.ip),
    );
  }

  final Uri baseUri;
  final http.Client _client;
  final bool _ownsClient;

  Future<SetupStatus> fetchStatus() {
    return _send('GET', baseUri.replace(path: '/v1/setup/status'));
  }

  Future<SetupStatus> submit({
    required String code,
    required String familyName,
    required String parentName,
    required String password,
  }) {
    return _send(
      'POST',
      baseUri.replace(path: '/v1/setup'),
      body: {
        'code': code,
        'family_name': familyName,
        'parent_name': parentName,
        'password': password,
      },
    );
  }

  Future<SetupStatus> _send(String method, Uri uri, {Map<String, String>? body}) async {
    final http.Response response;
    try {
      if (method == 'POST') {
        response = await _client
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 20));
      } else {
        response = await _client.get(uri).timeout(const Duration(seconds: 20));
      }
    } on SocketException {
      throw SetupException(_unreachable);
    } on http.ClientException {
      throw SetupException(_unreachable);
    }
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('not an object');
      }
      json = decoded;
    } on FormatException {
      throw SetupException('TinyWeb could not read the box.');
    }
    final status = SetupStatus.fromJson(json);
    if (response.statusCode != 200) {
      throw SetupException(status.error ?? 'TinyWeb could not start setup.');
    }
    return status;
  }

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

http.Client lanSetupClient(String ip) {
  final io = HttpClient();
  io.connectionTimeout = const Duration(seconds: 8);
  io.connectionFactory = (uri, host, port) {
    return Socket.startConnect(ip, port ?? uri.port);
  };
  return IOClient(io);
}

const String _unreachable =
    "Can't reach the TinyWeb on this Wi-Fi. Check that it has power and ethernet, and that this phone is on the same Wi-Fi.";
