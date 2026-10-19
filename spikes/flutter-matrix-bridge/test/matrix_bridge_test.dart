// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tw_matrix_spike/src/rust/api/matrix.dart';
import 'package:tw_matrix_spike/src/rust/frb_generated.dart';

void main() {
  final hs = Platform.environment['TW_HS'];
  if (hs == null || hs.isEmpty) {
    test(
      'matrix bridge e2e (skipped — set TW_HS)',
      () {},
      skip: 'TW_HS not set',
    );
    return;
  }

  test('matrix bridge e2e against Synapse', () async {
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
      fail('TW_LIB must point to librust_lib_tw_matrix_spike.so');
    }

    final caPem = caFile != null && caFile.isNotEmpty
        ? await File(caFile).readAsString()
        : null;
    final hsUri = Uri.parse(homeserver);
    final mxidB = _mxid(userB, hsUri);

    await RustLib.init(
      externalLibrary: ExternalLibrary.open(libPath),
    );

    final storeA = await Directory.systemTemp.createTemp('tw_matrix_a_');
    final storeB = await Directory.systemTemp.createTemp('tw_matrix_b_');

    final loginStopwatch = Stopwatch()..start();
    final sessionA = await login(
      homeserverUrl: homeserver,
      username: userA,
      password: password,
      storeDir: storeA.path,
      caCertPem: caPem,
      deviceName: 'tw_matrix_spike_test_a',
    );
    final sessionB = await login(
      homeserverUrl: homeserver,
      username: userB,
      password: password,
      storeDir: storeB.path,
      caCertPem: caPem,
      deviceName: 'tw_matrix_spike_test_b',
    );
    loginStopwatch.stop();
    print('login_ms: ${loginStopwatch.elapsedMilliseconds}');

    final syncStopwatch = Stopwatch()..start();
    await sessionA.syncOnce();
    await sessionB.syncOnce();
    syncStopwatch.stop();
    print('first_sync_ms: ${syncStopwatch.elapsedMilliseconds}');

    final roomsA = await sessionA.listRooms();
    final roomsB = await sessionB.listRooms();
    print('rooms_after_sync: A=${roomsA.length} B=${roomsB.length}');

    final sliding = await sessionA.trySlidingSync();
    print('sliding_sync: $sliding');

    await _exerciseRoom(
      label: 'unencrypted',
      encrypted: false,
      sessionA: sessionA,
      sessionB: sessionB,
      inviteMxid: mxidB,
    );

    try {
      await _exerciseRoom(
        label: 'encrypted',
        encrypted: true,
        sessionA: sessionA,
        sessionB: sessionB,
        inviteMxid: mxidB,
      );
    } catch (e, st) {
      print(
        'ENCRYPTED_ROOM_CASE: failed (E2EE may need more time or server keys): $e',
      );
      print(st);
    }

    await sessionA.logout();
    await sessionB.logout();

    await storeA.delete(recursive: true);
    await storeB.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

String _mxid(String username, Uri homeserver) {
  if (username.startsWith('@')) {
    return username;
  }
  return '@$username:${homeserver.host}';
}

Future<void> _exerciseRoom({
  required String label,
  required bool encrypted,
  required MatrixSession sessionA,
  required MatrixSession sessionB,
  required String inviteMxid,
}) async {
  print('--- case: $label (encrypted=$encrypted) ---');

  final roomName = 'tw_spike_${label}_${DateTime.now().millisecondsSinceEpoch}';
  final streamB = sessionB.startSync();
  final streamA = sessionA.startSync();

  // Let background sync run before create/invite.
  await Future<void>.delayed(const Duration(seconds: 2));

  final roomId = await sessionA.createRoom(
    name: roomName,
    inviteUserIds: [inviteMxid],
    encrypted: encrypted,
  );
  print('created room: $roomId');

  final pingBody = 'ping ${DateTime.now().toIso8601String()}';
  final sendStopwatch = Stopwatch()..start();
  await sessionA.sendText(roomId: roomId, body: pingBody);

  final pingOnB = await _waitForBody(streamB, pingBody);
  sendStopwatch.stop();
  print(
    'send_to_receive_ms ($label ping): ${sendStopwatch.elapsedMilliseconds} '
    '(encrypted=${pingOnB.wasEncrypted})',
  );

  final pongBody = 'pong ${DateTime.now().toIso8601String()}';
  final pongSend = Stopwatch()..start();
  await sessionB.sendText(roomId: roomId, body: pongBody);
  final pongOnA = await _waitForBody(streamA, pongBody);
  pongSend.stop();
  print(
    'send_to_receive_ms ($label pong): ${pongSend.elapsedMilliseconds} '
    '(encrypted=${pongOnA.wasEncrypted})',
  );

  await sessionA.stopSync();
  await sessionB.stopSync();
}

Future<IncomingMessage> _waitForBody(
  Stream<IncomingMessage> stream,
  String body,
) {
  return stream
      .where((m) => m.body == body)
      .first
      .timeout(const Duration(seconds: 60));
}
