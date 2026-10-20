import 'dart:async';

import 'package:flutter/foundation.dart';
import '../api/models.dart';
import '../matrix/matrix_session_opener.dart';
import '../rust/api/matrix.dart' as rust;
import '../storage/credential_store.dart';
import 'chat_message_mapper.dart';
import 'chat_models.dart';

abstract class ChatService {
  bool get isConfigured;

  ValueListenable<List<ChatRoom>> get roomsListenable;

  List<ChatRoom> get rooms;

  Stream<ChatSyncEvent> get syncEvents;

  Future<void> refreshRooms();

  Future<List<ChatMessage>> loadTimeline(String roomId, {int limit = 50});

  Future<List<ChatMember>> loadMembers(String roomId);

  Future<String> sendMessage(String roomId, String body);

  Future<String> sendMedia(
    String roomId,
    String filePath,
    String mimeType, {
    String? caption,
  });

  Future<String> downloadMedia(String roomId, String eventId);

  Future<String> downloadThumbnail(String roomId, String eventId);

  Future<String> createDirectChat(String userId);

  Future<void> startSync();

  Future<void> stopSync();

  Future<void> dispose();
}

class ChatSyncEvent {
  ChatSyncEvent.message(this.roomId, this.message) : roomsChanged = false;
  ChatSyncEvent.roomsChanged() : roomId = null, message = null, roomsChanged = true;

  final String? roomId;
  final ChatMessage? message;
  final bool roomsChanged;
}

class ChatMember {
  ChatMember({required this.userId, this.displayName});

  final String userId;
  final String? displayName;
}

class UnconfiguredChatService implements ChatService {
  UnconfiguredChatService() : _rooms = ValueNotifier(const []);

  final ValueNotifier<List<ChatRoom>> _rooms;
  final _sync = StreamController<ChatSyncEvent>.broadcast();

  @override
  bool get isConfigured => false;

  @override
  ValueListenable<List<ChatRoom>> get roomsListenable => _rooms;

  @override
  List<ChatRoom> get rooms => _rooms.value;

  @override
  Stream<ChatSyncEvent> get syncEvents => _sync.stream;

  @override
  Future<void> refreshRooms() async {}

  @override
  Future<List<ChatMessage>> loadTimeline(String roomId, {int limit = 50}) async =>
      [];

  @override
  Future<List<ChatMember>> loadMembers(String roomId) async => [];

  @override
  Future<String> sendMessage(String roomId, String body) async {
    throw StateError('Chat not configured');
  }

  @override
  Future<String> sendMedia(
    String roomId,
    String filePath,
    String mimeType, {
    String? caption,
  }) async {
    throw StateError('Chat not configured');
  }

  @override
  Future<String> downloadMedia(String roomId, String eventId) async {
    throw StateError('Chat not configured');
  }

  @override
  Future<String> downloadThumbnail(String roomId, String eventId) async {
    throw StateError('Chat not configured');
  }

  @override
  Future<String> createDirectChat(String userId) async {
    throw StateError('Chat not configured');
  }

  @override
  Future<void> startSync() async {}

  @override
  Future<void> stopSync() async {}

  @override
  Future<void> dispose() async {
    await _sync.close();
    _rooms.dispose();
  }
}

class FakeChatService implements ChatService {
  FakeChatService({List<ChatRoom>? initialRooms}) : forbiddenSend = false {
    _rooms = ValueNotifier(List<ChatRoom>.from(initialRooms ?? []));
    for (final r in _rooms.value) {
      _timelines[r.roomId] = [];
    }
  }

  late final ValueNotifier<List<ChatRoom>> _rooms;
  final Map<String, List<ChatMessage>> _timelines = {};
  final _sync = StreamController<ChatSyncEvent>.broadcast();
  bool forbiddenSend;

  /// Local paths returned by [downloadMedia] / [downloadThumbnail] for fakes.
  final Map<String, String> mediaPaths = {};
  final Map<String, String> thumbnailPaths = {};

  @override
  bool get isConfigured => true;

  @override
  ValueListenable<List<ChatRoom>> get roomsListenable => _rooms;

  @override
  List<ChatRoom> get rooms => _rooms.value;

  @override
  Stream<ChatSyncEvent> get syncEvents => _sync.stream;

  @override
  Future<void> refreshRooms() async {
    final sorted = [..._rooms.value];
    sorted.sort(
      (a, b) => (b.lastTsMs ?? 0).compareTo(a.lastTsMs ?? 0),
    );
    _rooms.value = sorted;
  }

  @override
  Future<List<ChatMessage>> loadTimeline(String roomId, {int limit = 50}) async {
    return List<ChatMessage>.from(_timelines[roomId] ?? const []);
  }

  void injectMessage(String roomId, ChatMessage message) {
    _timelines.putIfAbsent(roomId, () => []).add(message);
  }

  @override
  Future<List<ChatMember>> loadMembers(String roomId) async => [
        ChatMember(userId: '@alice:family.test', displayName: 'Alice'),
        ChatMember(userId: '@bob:family.test', displayName: 'Bob'),
      ];

  @override
  Future<String> sendMessage(String roomId, String body) async {
    if (forbiddenSend) {
      throw ChatSendException('forbidden: Not allowed during quiet hours');
    }
    final id = 'evt_${DateTime.now().microsecondsSinceEpoch}';
    final msg = ChatMessage(
      eventId: id,
      body: body,
      senderId: '@me:family.test',
      senderDisplayName: 'Me',
      tsMs: DateTime.now().millisecondsSinceEpoch,
      isOwn: true,
    );
    _timelines.putIfAbsent(roomId, () => []).add(msg);
    _updateRoomPreview(roomId, body, msg.tsMs);
    _sync.add(ChatSyncEvent.message(roomId, msg));
    return id;
  }

  @override
  Future<String> sendMedia(
    String roomId,
    String filePath,
    String mimeType, {
    String? caption,
  }) async {
    if (forbiddenSend) {
      throw ChatSendException('forbidden: Not allowed during quiet hours');
    }
    final id = 'evt_${DateTime.now().microsecondsSinceEpoch}';
    final name = filePath.split('/').last;
    final isVideo = mimeType.startsWith('video/');
    final body = (caption != null && caption.isNotEmpty)
        ? caption
        : '[$name]';
    final msg = ChatMessage(
      eventId: id,
      body: body,
      senderId: '@me:family.test',
      senderDisplayName: 'Me',
      tsMs: DateTime.now().millisecondsSinceEpoch,
      isOwn: true,
      msgtype: isVideo ? 'm.video' : 'm.image',
      filename: name,
      mimeType: mimeType,
    );
    mediaPaths[id] = filePath;
    thumbnailPaths[id] = filePath;
    _timelines.putIfAbsent(roomId, () => []).add(msg);
    _updateRoomPreview(roomId, body, msg.tsMs);
    _sync.add(ChatSyncEvent.message(roomId, msg));
    return id;
  }

  @override
  Future<String> downloadMedia(String roomId, String eventId) async {
    final path = mediaPaths[eventId];
    if (path == null) {
      throw StateError('no fake media for $eventId');
    }
    return path;
  }

  @override
  Future<String> downloadThumbnail(String roomId, String eventId) async {
    final path = thumbnailPaths[eventId] ?? mediaPaths[eventId];
    if (path == null) {
      throw StateError('no fake thumbnail for $eventId');
    }
    return path;
  }

  void _updateRoomPreview(String roomId, String body, int tsMs) {
    final list = [..._rooms.value];
    final idx = list.indexWhere((r) => r.roomId == roomId);
    if (idx >= 0) {
      final old = list[idx];
      list[idx] = ChatRoom(
        roomId: old.roomId,
        title: old.title,
        lastMessage: body,
        lastTsMs: tsMs,
        unread: old.unread,
        isDirect: old.isDirect,
      );
    }
    list.sort((a, b) => (b.lastTsMs ?? 0).compareTo(a.lastTsMs ?? 0));
    _rooms.value = list;
  }

  @override
  Future<String> createDirectChat(String userId) async {
    final roomId = '!dm_$userId:fake';
    _rooms.value = [
      ChatRoom(
        roomId: roomId,
        title: userId,
        isDirect: true,
        lastTsMs: DateTime.now().millisecondsSinceEpoch,
      ),
      ..._rooms.value,
    ];
    _timelines[roomId] = [];
    return roomId;
  }

  @override
  Future<void> startSync() async {}

  @override
  Future<void> stopSync() async {}

  @override
  Future<void> dispose() async {
    await _sync.close();
    _rooms.dispose();
  }
}

class ChatSendException implements Exception {
  ChatSendException(this.message);
  final String message;

  @override
  String toString() => message;
}

class RustChatService implements ChatService {
  RustChatService({
    required this.bundle,
    required this.credentialStore,
    this.caCertPem,
  });

  final EnrollmentBundle bundle;
  final CredentialStore credentialStore;
  final String? caCertPem;

  rust.MatrixSession? _session;
  StreamSubscription<rust.SyncEvent>? _syncSub;
  final ValueNotifier<List<ChatRoom>> _rooms = ValueNotifier(const []);
  final _sync = StreamController<ChatSyncEvent>.broadcast();

  @override
  bool get isConfigured => bundle.matrixEnrollment.isOk;

  @override
  ValueListenable<List<ChatRoom>> get roomsListenable => _rooms;

  @override
  List<ChatRoom> get rooms => _rooms.value;

  @override
  Stream<ChatSyncEvent> get syncEvents => _sync.stream;

  Future<void> start() async {
    if (!isConfigured) {
      return;
    }
    _session = await openMatrixSession(
      bundle: bundle,
      store: credentialStore,
      caCertPem: caCertPem,
    );
    await refreshRooms();
    await startSync();
  }

  rust.MatrixSession get _s {
    final s = _session;
    if (s == null) {
      throw StateError('Matrix session not started');
    }
    return s;
  }

  @override
  Future<void> refreshRooms() async {
    final raw = await _s.listRooms();
    final mapped = raw
        .map(
          (r) => ChatRoom(
            roomId: r.roomId,
            title: r.name,
            lastMessage: r.lastMessage,
            lastTsMs: r.lastTsMs?.toInt(),
            unread: r.unread.toInt(),
            isDirect: r.isDirect,
            encrypted: r.isEncrypted,
          ),
        )
        .toList();
    _rooms.value = mapped;
  }

  @override
  Future<List<ChatMessage>> loadTimeline(String roomId, {int limit = 50}) async {
    final raw = await _s.roomTimeline(roomId: roomId, limit: limit);
    return raw.map(chatMessageFromTimeline).toList();
  }

  @override
  Future<List<ChatMember>> loadMembers(String roomId) async {
    final raw = await _s.roomMembers(roomId: roomId);
    return raw
        .map((m) => ChatMember(userId: m.userId, displayName: m.displayName))
        .toList();
  }

  @override
  Future<String> sendMessage(String roomId, String body) async {
    try {
      return await _s.sendText(roomId: roomId, body: body);
    } catch (e) {
      final text = e.toString();
      if (text.contains('forbidden:')) {
        throw ChatSendException(text);
      }
      rethrow;
    }
  }

  @override
  Future<String> sendMedia(
    String roomId,
    String filePath,
    String mimeType, {
    String? caption,
  }) async {
    try {
      return await _s.sendMedia(
        roomId: roomId,
        filePath: filePath,
        mimeType: mimeType,
        caption: caption,
      );
    } catch (e) {
      final text = e.toString();
      if (text.contains('forbidden:')) {
        throw ChatSendException(text);
      }
      rethrow;
    }
  }

  @override
  Future<String> downloadMedia(String roomId, String eventId) async {
    return _s.downloadMedia(roomId: roomId, eventId: eventId);
  }

  @override
  Future<String> downloadThumbnail(String roomId, String eventId) async {
    return _s.downloadThumbnail(roomId: roomId, eventId: eventId);
  }

  @override
  Future<String> createDirectChat(String userId) async {
    return _s.createDirectChat(userId: userId);
  }

  @override
  Future<void> startSync() async {
    await stopSync();
    final stream = _s.startSync();
    _syncSub = stream.listen((event) {
      event.map(
        message: (wrapped) {
          final msg = wrapped.field0;
          _sync.add(ChatSyncEvent.message(msg.roomId, chatMessageFromIncoming(msg)));
        },
        roomsChanged: (_) {
          refreshRooms();
          _sync.add(ChatSyncEvent.roomsChanged());
        },
      );
    });
  }

  @override
  Future<void> stopSync() async {
    await _syncSub?.cancel();
    _syncSub = null;
    await _session?.stopSync();
  }

  @override
  Future<void> dispose() async {
    await stopSync();
    await _sync.close();
    _rooms.dispose();
  }
}
