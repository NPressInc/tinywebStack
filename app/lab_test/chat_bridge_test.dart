// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/rust/api/matrix.dart';
import 'package:tinyweb/src/rust/frb_generated.dart';

import 'lab_env.dart';

void main() {
  installLabTestHttpOverrides();
  final hs = Platform.environment['TW_HS'];
  if (hs == null || hs.isEmpty) {
    test(
      'chat bridge e2e (skipped — set TW_HS)',
      () {},
      skip: 'TW_HS not set',
    );
    return;
  }

  test('chat bridge e2e against Synapse', () async {
    final homeserver = hs;
    final caFile = Platform.environment['TW_CA_FILE'];
    final userA = Platform.environment['TW_USER_A'] ?? 'bob';
    final userB = Platform.environment['TW_USER_B'] ?? 'alice';
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

    final storeA = await Directory.systemTemp.createTemp('tw_chat_a_');
    final storeB = await Directory.systemTemp.createTemp('tw_chat_b_');

    final passA = _randomPassphrase();
    final passB = _randomPassphrase();
    final sessionA = await login(
      homeserverUrl: homeserver,
      username: userA,
      password: password,
      storeDir: storeA.path,
      storePassphrase: passA,
      caCertPem: caPem,
      deviceName: 'tw_chat_bridge_test_a',
    );
    final sessionB = await login(
      homeserverUrl: homeserver,
      username: userB,
      password: password,
      storeDir: storeB.path,
      storePassphrase: passB,
      caCertPem: caPem,
      deviceName: 'tw_chat_bridge_test_b',
    );

    await sessionA.syncOnce();
    await sessionB.syncOnce();
    // Encrypted DMs need the SDK crypto stack ready before send/receive.
    await sessionA.encryptionStatus();
    await sessionB.encryptionStatus();

    final streamB = sessionB.startSync();
    await Future<void>.delayed(const Duration(seconds: 2));

    final roomId = await sessionA.createDirectChat(userId: mxidB);
    await sessionB.joinRoom(roomId: roomId);
    await sessionA.syncOnce();
    await sessionB.syncOnce();
    await Future<void>.delayed(const Duration(seconds: 2));

    final roomsB = await sessionB.listRooms();
    expect(
      roomsB.any((r) => r.roomId == roomId),
      isTrue,
      reason: 'B should see the DM after join/sync',
    );

    final pingBody = 'ping ${DateTime.now().toIso8601String()}';
    await sessionA.sendText(roomId: roomId, body: pingBody);

    final incoming = await _waitForBody(streamB, pingBody);
    expect(incoming.utd, isFalse);

    final timeline = await sessionA.roomTimeline(roomId: roomId, limit: 20);
    expect(
      timeline.any((m) => m.body == pingBody),
      isTrue,
      reason: 'room_timeline should contain sent message',
    );

    await sessionA.stopSync();
    await sessionB.stopSync();
    await sessionA.logout();
    await sessionB.logout();

    await storeA.delete(recursive: true);
    await storeB.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

String _randomPassphrase() {
  final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
  return base64Encode(bytes);
}

String _mxid(String username, Uri homeserver) {
  if (username.startsWith('@')) {
    return username;
  }
  return '@$username:${homeserver.host}';
}

Future<IncomingMessage> _waitForBody(
  Stream<SyncEvent> stream,
  String body,
) {
  return stream
      .map((e) => e.map(
            message: (m) => m.field0,
            roomsChanged: (_) => null,
            typing: (_) => null,
            reactionUpdated: (_) => null,
          ))
      .where((m) => m != null && m.body == body)
      .map((m) => m!)
      .first
      .timeout(const Duration(seconds: 90));
}
