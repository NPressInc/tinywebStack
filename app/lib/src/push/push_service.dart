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
import 'unified_push_instance.dart';

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
  bool _unifiedPushInitialized = false;

  /// Shown on Home when Android UnifiedPush endpoint does not match the family push origin.
  String? pushSetupDetail;

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
    pushSetupDetail = null;
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
      await _requestAndroidNotificationPermission();
      await syncFromEnrollment(bundle);
    } else {
      pushSetupDetail = null;
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

  Future<void> _initUnifiedPush(PushEnrollmentConfig config) async {
    if (_unifiedPushInitialized) {
      return;
    }
    _unifiedPushInitialized = true;
    await UnifiedPush.initialize(
      onNewEndpoint: (endpoint, _) async {
        final url = endpoint.url;
        if (!_endpointAllowed(url, config)) {
          pushSetupDetail =
              'Set the ntfy app\'s server to ${config.expectedPublicPushOrigin()}';
          return;
        }
        pushSetupDetail = null;
        await store.writeUnifiedPushEndpoint(url);
        final bundle = await store.read();
        if (bundle != null) {
          await syncFromEnrollment(bundle);
        }
      },
      onRegistrationFailed: (reason, instance) {
        pushSetupDetail =
            'Set the ntfy app\'s server to ${config.expectedPublicPushOrigin()}';
      },
      onUnregistered: (_) async {
        await unregisterPusher();
      },
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
  }

  bool _endpointAllowed(String endpoint, PushEnrollmentConfig config) {
    final origin = config.expectedPublicPushOrigin();
    if (origin.isEmpty) {
      return false;
    }
    final prefix = origin.endsWith('/') ? origin : '$origin/';
    return endpoint.startsWith(prefix);
  }

  Future<String?> _ensureAndroidPushkey(PushEnrollmentConfig config) async {
    await _requestAndroidNotificationPermission();
    await _initUnifiedPush(config);

    final cached = await store.readUnifiedPushEndpoint();
    if (cached != null && _endpointAllowed(cached, config)) {
      return cached;
    }

    var topic = await store.readUnifiedPushTopic();
    if (topic == null || topic.isEmpty) {
      topic = generateUnifiedPushInstanceId();
      await store.writeUnifiedPushTopic(topic);
    }
    await UnifiedPush.register(instance: topic);

    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final ep = await store.readUnifiedPushEndpoint();
      if (ep != null && _endpointAllowed(ep, config)) {
        return ep;
      }
    }
    pushSetupDetail =
        'Set the ntfy app\'s server to ${config.expectedPublicPushOrigin()}';
    return null;
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

  Future<void> _requestAndroidNotificationPermission() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final android = _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
    } catch (_) {
      // No platform implementation in unit tests.
    }
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
