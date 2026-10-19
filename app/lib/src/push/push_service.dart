import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../api/models.dart';
import '../matrix/matrix_session_opener.dart';
import '../rust/api/matrix.dart' as rust;
import '../storage/credential_store.dart';
import 'matrix_push_payload.dart';
import 'push_config.dart';

class PushService {
  PushService({
    required this.store,
    FlutterLocalNotificationsPlugin? notifications,
  }) : _notifications =
            notifications ?? FlutterLocalNotificationsPlugin();

  final CredentialStore store;
  final FlutterLocalNotificationsPlugin _notifications;
  static const _iosChannel = MethodChannel('tinyweb/push_ios');

  rust.MatrixSession? _matrix;
  String? _registeredPushkey;
  String? _registeredAppId;

  Future<void> syncFromEnrollment(EnrollmentBundle bundle) async {
    if (!bundle.matrixEnrollment.isOk) {
      return;
    }
    if (!(await store.areNotificationsEnabled())) {
      await unregisterPusher();
      return;
    }
    PushEnrollmentConfig config;
    try {
      config = PushEnrollmentConfig.fromBundle(bundle);
    } catch (_) {
      return;
    }

    final pushkey = await _ensurePushkey(config);
    if (pushkey == null || pushkey.isEmpty) {
      return;
    }

    final appId = _matrixAppId(config);
    if (_registeredPushkey == pushkey && _registeredAppId == appId) {
      return;
    }

    final ca = await _caPem();
    final session = await openMatrixSession(
      bundle: bundle,
      store: store,
      caCertPem: ca,
    );
    await session.setHttpPusher(
      appId: appId,
      pushkey: pushkey,
      gatewayUrl: _gatewayUrl(config),
      lang: 'en',
    );
    _matrix = session;
    _registeredPushkey = pushkey;
    _registeredAppId = appId;
    await store.writeMatrixPusherRegistration(appId: appId, pushkey: pushkey);
  }

  Future<void> unregisterPusher() async {
    final reg = await store.readMatrixPusherRegistration();
    if (reg == null) {
      return;
    }
    final bundle = await store.read();
    if (bundle != null && bundle.matrixEnrollment.isOk) {
      try {
        final session = _matrix ??
            await openMatrixSession(
              bundle: bundle,
              store: store,
              caCertPem: await _caPem(),
            );
        await session.deleteHttpPusher(
          appId: reg.appId,
          pushkey: reg.pushkey,
        );
      } catch (_) {
        // Best effort on sign-out.
      }
    }
    _registeredPushkey = null;
    _registeredAppId = null;
    await store.clearMatrixPusherRegistration();
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    await store.setNotificationsEnabled(enabled);
    final bundle = await store.read();
    if (bundle == null) {
      return;
    }
    if (enabled) {
      await syncFromEnrollment(bundle);
    } else {
      await unregisterPusher();
    }
  }

  Future<void> handleBackgroundPayload(String payload) async {
    final hint = MatrixPushHint.tryParse(payload);
    if (hint == null) {
      return;
    }
    if (hint.raw != null &&
        MatrixPushHint.containsForbiddenMessageContent(hint.raw!)) {
      return;
    }
    final bundle = await store.read();
    if (bundle == null || !bundle.matrixEnrollment.isOk) {
      await _showGenericNotification();
      return;
    }
    String title = 'TinyWeb';
    String body = 'New message';
    try {
      final session = _matrix ??
          await openMatrixSession(
            bundle: bundle,
            store: store,
            caCertPem: await _caPem(),
          );
      _matrix = session;
      final messages =
          await session.roomTimeline(roomId: hint.roomId, limit: 20);
      final match = messages.where((m) => m.eventId == hint.eventId).toList();
      if (match.isNotEmpty) {
        final msg = match.first;
        final sender = msg.senderDisplayName ?? msg.sender;
        body = '$sender: ${msg.body}';
      }
      final rooms = await session.listRooms();
      final room = rooms.where((r) => r.roomId == hint.roomId).toList();
      if (room.isNotEmpty && room.first.name.isNotEmpty) {
        title = room.first.name;
      }
    } catch (_) {
      // Encrypted or offline — generic text only.
    }
    await _showNotification(title: title, body: body);
  }

  String _matrixAppId(PushEnrollmentConfig config) {
    if (Platform.isIOS) {
      return config.iosAppId;
    }
    return config.androidAppId;
  }

  String _gatewayUrl(PushEnrollmentConfig config) {
    if (Platform.isIOS) {
      return config.sygnalGatewayUrl;
    }
    return config.unifiedGatewayUrl;
  }

  Future<String?> _ensurePushkey(PushEnrollmentConfig config) async {
    if (Platform.isAndroid) {
      return _ensureAndroidPushkey(config);
    }
    if (Platform.isIOS) {
      return _ensureIosPushkey();
    }
    return null;
  }

  Future<String?> _ensureAndroidPushkey(PushEnrollmentConfig config) async {
    final existing = await store.readUnifiedPushTopic();
    final topic = existing ?? _randomTopic();
    if (existing == null) {
      await store.writeUnifiedPushTopic(topic);
    }
    await UnifiedPush.initialize(
      onNewEndpoint: (endpoint, _) async {
        await store.writeUnifiedPushEndpoint(endpoint.url);
      },
      onRegistrationFailed: (reason, instance) {
        // Distributor unavailable; user can install ntfy as UnifiedPush distributor.
      },
      onUnregistered: (_) {},
      onMessage: (message, _) async {
        await handleBackgroundPayload(String.fromCharCodes(message.content));
      },
    );
    if (await UnifiedPush.getDistributor() == null) {
      final distributors = await UnifiedPush.getDistributors();
      if (distributors.isNotEmpty) {
        await UnifiedPush.saveDistributor(distributors.first);
      } else {
        await UnifiedPush.tryUseCurrentOrDefaultDistributor();
      }
    }
    await UnifiedPush.register(instance: topic);
    return topic;
  }

  Future<String?> _ensureIosPushkey() async {
    final cached = await store.readApnsTokenHex();
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    try {
      final token = await _iosChannel.invokeMethod<String>('requestToken');
      if (token != null && token.isNotEmpty) {
        await store.writeApnsTokenHex(token);
        return token;
      }
    } catch (_) {}
    return null;
  }

  String _randomTopic() {
    final bytes = List<int>.generate(24, (i) => (i * 17 + 91) % 256);
    return 'tw-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  Future<void> _initNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _notifications.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );
  }

  Future<void> _showGenericNotification() async {
    await _showNotification(title: 'TinyWeb', body: 'New message');
  }

  Future<void> _showNotification({
    required String title,
    required String body,
  }) async {
    await _initNotifications();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'tinyweb_messages',
        'Messages',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }

  Future<String?> _caPem() async {
    final pem = Platform.environment['TW_CA_FILE'];
    if (pem == null || pem.isEmpty) {
      return null;
    }
    try {
      return await File(pem).readAsString();
    } catch (_) {
      return null;
    }
  }
}
