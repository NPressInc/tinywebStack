// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:tinyweb/src/rust/api/matrix.dart';
import 'package:tinyweb/src/rust/frb_generated.dart';

void main() {
  final hs = Platform.environment['TW_HS'];
  if (hs == null || hs.isEmpty) {
    test(
      'e2ee bridge (skipped — set TW_HS)',
      () {},
      skip: 'TW_HS not set',
    );
    return;
  }

  test('e2ee bridge against Synapse', () async {
    final homeserver = hs;
    final caFile = Platform.environment['TW_CA_FILE'];
    final userA = Platform.environment['TW_USER_A'] ?? 'parent';
    final userB = Platform.environment['TW_USER_B'] ?? 'kid';
    final password = Platform.environment['TW_TEST_PASSWORD'];
    final libPath = Platform.environment['TW_LIB'];
    if (password == null || password.isEmpty) {
      fail('TW_TEST_PASSWORD must be set');
    }
    if (libPath == null || libPath.isEmpty) {
      fail('TW_LIB must point to libtinyweb_core.so');
    }

    final caPem = caFile != null && caFile.isNotEmpty
        ? await File(caFile).readAsString()
        : null;
    final hsUri = Uri.parse(homeserver);
    final mxidB = _mxid(userB, hsUri);

    await RustLib.init(
      externalLibrary: ExternalLibrary.open(libPath),
    );

    final storeA1 = await Directory.systemTemp.createTemp('tw_e2ee_a1_');
    final storeB = await Directory.systemTemp.createTemp('tw_e2ee_b_');

    final sessionA1 = await login(
      homeserverUrl: homeserver,
      username: userA,
      password: password,
      storeDir: storeA1.path,
      storePassphrase: _randomPassphrase(),
      caCertPem: caPem,
      deviceName: 'tw_e2ee_test_a1',
    );
    final sessionB = await login(
      homeserverUrl: homeserver,
      username: userB,
      password: password,
      storeDir: storeB.path,
      storePassphrase: _randomPassphrase(),
      caCertPem: caPem,
      deviceName: 'tw_e2ee_test_b',
    );
    await sessionA1.syncOnce();
    await sessionB.syncOnce();

    final recoveryKeyA = await sessionA1.resetRecovery(password: password);
    await sessionB.resetRecovery(password: password);

    final streamB = sessionB.startSync();
    await Future<void>.delayed(const Duration(seconds: 2));

    final roomId = await sessionA1.createDirectChat(userId: mxidB);
    await sessionB.joinRoom(roomId: roomId);
    await sessionA1.syncOnce();
    await sessionB.syncOnce();
    await Future<void>.delayed(const Duration(seconds: 3));

    final pingBody = 'e2ee ping ${DateTime.now().toIso8601String()}';
    final eventId = await sessionA1.sendText(roomId: roomId, body: pingBody);

    final incoming = await _waitForBody(streamB, pingBody);
    expect(incoming.wasEncrypted, isTrue);

    final replyBody = 'e2ee reply ${DateTime.now().toIso8601String()}';
    await sessionB.sendText(roomId: roomId, body: replyBody);
    await _waitForTimelineBody(sessionA1, roomId, replyBody);

    await sessionA1.flushKeyBackup();
    await sessionA1.syncOnce();
    await Future<void>.delayed(const Duration(seconds: 5));

    final rawEvent = await _fetchRawEvent(
      homeserver: homeserver,
      caFile: caFile,
      roomId: roomId,
      eventId: eventId,
      accessToken: await _accessToken(homeserver, userA, password),
    );
    expect(rawEvent['type'], 'm.room.encrypted');
    final encoded = jsonEncode(rawEvent);
    expect(encoded.contains(pingBody), isFalse);

    await sessionA1.stopSync();
    await sessionB.stopSync();
    await sessionA1.logout();
    await sessionB.logout();

    final storeA2 = await Directory.systemTemp.createTemp('tw_e2ee_a2_');
    final sessionA2 = await login(
      homeserverUrl: homeserver,
      username: userA,
      password: password,
      storeDir: storeA2.path,
      storePassphrase: _randomPassphrase(),
      caCertPem: caPem,
      deviceName: 'tw_e2ee_test_a2',
    );
    await sessionA2.syncOnce();
    await sessionA2.recover(recoveryKey: recoveryKeyA);
    await sessionA2.joinRoom(roomId: roomId);
    await sessionA2.syncOnce();
    await sessionA2.downloadRoomKeyBackup(roomId: roomId);
    await _waitForTimelineBody(sessionA2, roomId, pingBody);

    await sessionA2.stopSync();
    await sessionA2.logout();
    await storeA2.delete(recursive: true);

    await storeA1.delete(recursive: true);
    await storeB.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 20)));
}

String _mxid(String username, Uri homeserver) {
  if (username.startsWith('@')) {
    return username;
  }
  return '@$username:${homeserver.host}';
}

String _randomPassphrase() {
  final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
  return base64Encode(bytes);
}

Future<String> _accessToken(
  String homeserver,
  String user,
  String password,
) async {
  final hsUri = Uri.parse(homeserver);
  final loginUrl = hsUri.replace(
    path: '${hsUri.path.replaceAll(RegExp(r'/$'), '')}/_matrix/client/v3/login',
  );
  final localpart = user.startsWith('@') ? user.split(':').first.substring(1) : user;
  final body = {
    'type': 'm.login.password',
    'identifier': {
      'type': 'm.id.user',
      'user': localpart,
    },
    'password': password,
  };
  final client = caFileHttpClient(Platform.environment['TW_CA_FILE']);
  final resp = await client.post(
    loginUrl,
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(body),
  );
  expect(resp.statusCode, 200);
  final json = jsonDecode(resp.body) as Map<String, dynamic>;
  return json['access_token'] as String;
}

http.Client caFileHttpClient(String? caFile) {
  if (caFile == null || caFile.isEmpty) {
    return http.Client();
  }
  final context = SecurityContext(withTrustedRoots: true)
    ..setTrustedCertificatesBytes(File(caFile).readAsBytesSync());
  final ioClient = HttpClient(context: context);
  return IOClient(ioClient);
}

Future<Map<String, dynamic>> _fetchRawEvent({
  required String homeserver,
  required String? caFile,
  required String roomId,
  required String eventId,
  required String accessToken,
}) async {
  final hsUri = Uri.parse(homeserver);
  final path =
      '${hsUri.path.replaceAll(RegExp(r'/$'), '')}/_matrix/client/v3/rooms/${Uri.encodeComponent(roomId)}/event/${Uri.encodeComponent(eventId)}';
  final url = hsUri.replace(path: path);
  final client = caFileHttpClient(caFile);
  final resp = await client.get(
    url,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  expect(resp.statusCode, 200);
  return jsonDecode(resp.body) as Map<String, dynamic>;
}

Future<IncomingMessage> _waitForBody(
  Stream<SyncEvent> stream,
  String body,
) {
  return stream
      .map((e) => e.map(
            message: (m) => m.field0,
            roomsChanged: (_) => null,
          ))
      .where((m) => m != null && m.body == body)
      .map((m) => m!)
      .first
      .timeout(const Duration(seconds: 90));
}

Future<void> _waitForTimelineBody(
  MatrixSession session,
  String roomId,
  String body,
) async {
  for (var i = 0; i < 30; i++) {
    await session.syncOnce();
    final timeline = await session.roomTimeline(roomId: roomId, limit: 30);
    if (timeline.any((m) => m.body == body)) {
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  fail('timed out waiting for timeline body: $body');
}
