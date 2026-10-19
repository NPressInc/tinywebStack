// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/push/matrix_push_payload.dart';
import 'package:tinyweb/src/push/push_config.dart';
import 'package:tinyweb/src/rust/api/matrix.dart';
import 'package:tinyweb/src/rust/frb_generated.dart';

import 'lab_env.dart';

void main() {
  installLabTestHttpOverrides();
  final origin = Platform.environment['TW_HS'];
  if (origin == null || origin.isEmpty) {
    test('push e2e (skipped — set TW_HS)', () {}, skip: 'TW_HS not set');
    return;
  }

  test('matrix push via ntfy topic has no message body', () async {
    final password = Platform.environment['TW_TEST_PASSWORD'];
    final libPath = Platform.environment['TW_LIB'];
    final kidUser = Platform.environment['TW_KID_USER'] ?? 'kid';
    final parentUser = Platform.environment['TW_PARENT_USER'] ?? 'parent';
    if (password == null || password.isEmpty) {
      fail('TW_TEST_PASSWORD must be set');
    }
    if (libPath == null || libPath.isEmpty) {
      fail('TW_LIB must point to libtinyweb_core.so');
    }
    final caFile = Platform.environment['TW_CA_FILE'];
    final caPem = caFile != null && caFile.isNotEmpty
        ? await File(caFile).readAsString()
        : null;

    final httpClient = http.Client();
    final discovery = await DiscoveryClient(client: httpClient).fetch(origin);
    final api = FamilyApiClient(client: httpClient);

    final kidBundle = await api.enroll(
      discovery: discovery,
      method: 'password',
      username: kidUser,
      password: password,
      deviceName: 'tw_push_lab_kid',
    );
    final push = PushEnrollmentConfig.fromBundle(kidBundle);
    final topic = 'tw-lab-${Random.secure().nextInt(1 << 30)}';
    final publicBase = push.publicBase ?? origin.replaceFirst('https://', 'https://push.');
    final pollUrl = '${publicBase.replaceAll(RegExp(r'/+$'), '')}/$topic/json?poll=1';

    await RustLib.init(externalLibrary: ExternalLibrary.open(libPath));
    final storeDir = await Directory.systemTemp.createTemp('tw_push_kid_');
    final matrix = kidBundle.matrixEnrollment;
    expect(matrix.isOk, isTrue);
    final sessionKid = await restoreSession(
      homeserverUrl: matrix.homeserver!,
      userId: matrix.userId!,
      deviceId: matrix.deviceId!,
      accessToken: matrix.accessToken!,
      storeDir: storeDir.path,
      storePassphrase: _randomPassphrase(),
      caCertPem: caPem,
    );
    await sessionKid.setHttpPusher(
      appId: push.androidAppId,
      pushkey: topic,
      gatewayUrl: push.unifiedGatewayUrl,
    );

    final parentStore = await Directory.systemTemp.createTemp('tw_push_parent_');
    final sessionParent = await login(
      homeserverUrl: matrix.homeserver!,
      username: parentUser,
      password: password,
      storeDir: parentStore.path,
      storePassphrase: _randomPassphrase(),
      caCertPem: caPem,
      deviceName: 'tw_push_lab_parent',
    );
    await sessionParent.syncOnce();
    await sessionKid.syncOnce();
    final mxidKid = kidBundle.mxid;
    final roomId = await sessionParent.createDirectChat(userId: mxidKid);
    await sessionKid.joinRoom(roomId: roomId);

    final secretBody = 'push-lab-secret-${DateTime.now().microsecondsSinceEpoch}';
    final pollFuture = _pollNtfyOnce(httpClient, pollUrl, timeout: const Duration(seconds: 45));

    await sessionParent.sendText(roomId: roomId, body: secretBody);
    final rawLine = await pollFuture;
    expect(rawLine, isNotNull, reason: 'expected ntfy notification on topic');
    expect(rawLine!.contains(secretBody), isFalse,
        reason: 'push payload must not contain message body');
    final hint = MatrixPushHint.tryParse(rawLine);
    expect(hint, isNotNull);
    expect(hint!.eventId, isNotEmpty);
    final decoded = jsonDecode(rawLine) as Map<String, dynamic>;
    expect(MatrixPushHint.containsForbiddenMessageContent(decoded), isFalse);

    await sessionKid.deleteHttpPusher(
      appId: push.androidAppId,
      pushkey: topic,
    );
    httpClient.close();
  });
}

Future<String?> _pollNtfyOnce(
  http.Client client,
  String pollUrl, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final resp = await client.get(Uri.parse(pollUrl));
    if (resp.statusCode == 200 && resp.body.trim().isNotEmpty) {
      return resp.body.trim();
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  return null;
}

String _randomPassphrase() {
  final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
  return base64Encode(bytes);
}
