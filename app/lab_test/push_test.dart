// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/api/tls_http_client.dart';
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

  test('matrix push via Synapse→ntfy has no message body', () async {
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

    final httpClient = tlsHttpClientFromEnvironment();
    final discovery = await DiscoveryClient(client: httpClient).fetch(origin);
    final api = FamilyApiClient(client: httpClient);

    final parentBundle = await api.enroll(
      discovery: discovery,
      method: 'password',
      username: parentUser,
      password: password,
      deviceName: 'tw_push_lab_parent',
    );
    final push = PushEnrollmentConfig.fromBundle(parentBundle);
    final topic = _randomUpTopic();
    final publicBase = push.expectedPublicPushOrigin();
    expect(publicBase, isNotEmpty);
    final pushkey = '$publicBase/$topic?up=1';
    final pollUrl = '$publicBase/$topic/json?poll=1';

    await RustLib.init(externalLibrary: ExternalLibrary.open(libPath));
    final storeDir = await Directory.systemTemp.createTemp('tw_push_parent_');
    final matrix = parentBundle.matrixEnrollment;
    expect(matrix.isOk, isTrue);
    final sessionParent = await restoreSession(
      homeserverUrl: matrix.homeserver!,
      userId: matrix.userId!,
      deviceId: matrix.deviceId!,
      accessToken: matrix.accessToken!,
      storeDir: storeDir.path,
      storePassphrase: _randomPassphrase(),
      caCertPem: caPem,
    );
    await sessionParent.setHttpPusher(
      appId: push.androidAppId,
      pushkey: pushkey,
      gatewayUrl: push.unifiedGatewayUrl,
    );

    final kidStore = await Directory.systemTemp.createTemp('tw_push_kid_');
    final sessionKid = await login(
      homeserverUrl: matrix.homeserver!,
      username: kidUser,
      password: password,
      storeDir: kidStore.path,
      storePassphrase: _randomPassphrase(),
      caCertPem: caPem,
      deviceName: 'tw_push_lab_kid',
    );
    await sessionParent.syncOnce();
    await sessionKid.syncOnce();
    final mxidKid = '@$kidUser:${parentBundle.serverName}';
    final roomId = await sessionParent.createRoom(
      name: 'tw-push-lab',
      inviteUserIds: [mxidKid],
      encrypted: false,
    );
    await sessionKid.joinRoom(roomId: roomId);

    final secretBody = 'push-lab-secret-${DateTime.now().microsecondsSinceEpoch}';
    final pollFuture = _pollNtfyOnce(
      httpClient,
      pollUrl,
      timeout: const Duration(seconds: 45),
    );

    final eventId = await sessionKid.sendText(roomId: roomId, body: secretBody);
    final rawLine = await pollFuture;
    expect(rawLine, isNotNull, reason: 'expected Synapse→ntfy notification on topic');
    expect(rawLine!.contains(secretBody), isFalse,
        reason: 'push payload must not contain message body');

    final ntfyJson = jsonDecode(rawLine) as Map<String, dynamic>;
    final inner = ntfyJson['message'] as String? ?? rawLine;
    final hint = MatrixPushHint.tryParse(inner);
    expect(hint, isNotNull);
    expect(hint!.eventId, eventId);
    final parsedInner = jsonDecode(inner) as Map<String, dynamic>;
    expect(
      MatrixPushHint.containsForbiddenMessageContent(parsedInner),
      isFalse,
    );

    await sessionParent.deleteHttpPusher(
      appId: push.androidAppId,
      pushkey: pushkey,
    );
    httpClient.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

String _randomUpTopic() {
  const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final r = Random.secure();
  return 'up${List.generate(16, (_) => chars[r.nextInt(chars.length)]).join()}';
}

Future<String?> _pollNtfyOnce(
  dynamic client,
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
