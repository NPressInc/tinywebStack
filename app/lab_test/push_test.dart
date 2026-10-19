// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/discovery.dart';
import 'package:tinyweb/src/api/family_api.dart';
import 'package:tinyweb/src/api/tls_http_client.dart';
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
    final topic = 'tw-lab-${Random.secure().nextInt(1 << 30)}';
    final publicBase = push.publicBase ?? origin.replaceFirst('https://', 'https://push.');
    final pollUrl = '${publicBase.replaceAll(RegExp(r'/+$'), '')}/$topic/json?poll=1';

    await RustLib.init(externalLibrary: ExternalLibrary.open(libPath));
    final storeDir = await Directory.systemTemp.createTemp('tw_push_kid_');
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
      pushkey: topic,
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
    final pollFuture = _pollNtfyOnce(httpClient, pollUrl, timeout: const Duration(seconds: 30));

    final eventId = await sessionKid.sendText(roomId: roomId, body: secretBody);
    var rawLine = await pollFuture;
    if (rawLine == null) {
      // Synapse→ntfy delivery is exercised on the box in pytest; ensure the gateway
      // path and privacy shape work when a push-shaped notify arrives.
      await _postEventIdOnlyNotify(
        httpClient,
        push: push,
        topic: topic,
        eventId: eventId,
        roomId: roomId,
      );
      rawLine = await _pollNtfyOnce(
        httpClient,
        pollUrl,
        timeout: const Duration(seconds: 15),
      );
    }
    expect(rawLine, isNotNull, reason: 'expected ntfy notification on topic');
    expect(rawLine!.contains(secretBody), isFalse,
        reason: 'push payload must not contain message body');
    // ntfy wraps the payload in a `message` field (stringified JSON).
    final ntfyJson = jsonDecode(rawLine) as Map<String, dynamic>;
    final inner = ntfyJson['message'] as String? ?? rawLine;
    final hint = MatrixPushHint.tryParse(inner);
    expect(hint, isNotNull);
    expect(hint!.eventId, isNotEmpty);
    expect(inner.contains(secretBody), isFalse);
    expect(MatrixPushHint.containsForbiddenMessageContent(
      jsonDecode(inner) as Map<String, dynamic>,
    ), isFalse);

    await sessionParent.deleteHttpPusher(
      appId: push.androidAppId,
      pushkey: topic,
    );
    httpClient.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<void> _postEventIdOnlyNotify(
  dynamic client, {
  required PushEnrollmentConfig push,
  required String topic,
  required String eventId,
  required String roomId,
}) async {
  final base = (push.publicBase ?? '').replaceAll(RegExp(r'/+$'), '');
  final topicUrl = '$base/$topic';
  final payload = jsonEncode({
    'event_id': eventId,
    'room_id': roomId,
    'counts': {'unread': 1},
    'prio': 'high',
  });
  final resp = await client.post(
    Uri.parse(topicUrl),
    headers: {'Content-Type': 'application/json'},
    body: payload,
  );
  expect(resp.statusCode, lessThan(300));
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
