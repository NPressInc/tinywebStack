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

  /// Session scope for URL preview negative caching (homeserver base URL or similar).
  String get urlPreviewCacheKey;

  ValueListenable<List<ChatRoom>> get roomsListenable;

  List<ChatRoom> get rooms;

  Stream<ChatSyncEvent> get syncEvents;

  Future<void> refreshRooms();

  Future<List<ChatMessage>> loadTimeline(String roomId, {int limit = 50});

  Future<List<ChatMember>> loadMembers(String roomId);

  Future<String> sendMessage(String roomId, String body);

  Future<String> sendReply(String roomId, String body, String replyToEventId);

  Future<String> sendReaction(String roomId, String eventId, String emoji);

  Future<void> redactEvent(String roomId, String eventId, {String? reason});

  Future<void> setTyping(String roomId, bool typing);

  Future<void> sendReadReceipt(String roomId, String eventId);

  Future<List<ChatReadReceipt>> readReceiptsForEvent(String roomId, String eventId);

  Future<ChatUrlPreview> fetchUrlPreview(String url);

  Future<String> sendMedia(
    String roomId,
    String filePath,
    String mimeType, {
    String? caption,
  });

  Future<String> downloadMedia(String roomId, String eventId);

  Future<String> downloadThumbnail(String roomId, String eventId);

  Future<String> createDirectChat(String userId);

  Future<String> createGroupChat(String name, List<String> userIds);

  Future<void> startSync();

  Future<void> stopSync();

  Future<void> dispose();
}

class ChatSyncEvent {
  ChatSyncEvent.message(this.roomId, this.message)
      : roomsChanged = false,
        typingUserIds = null,
        reactionUpdate = null;
  ChatSyncEvent.roomsChanged()
      : roomId = null,
        message = null,
        roomsChanged = true,
        typingUserIds = null,
        reactionUpdate = null;
  ChatSyncEvent.typing(this.roomId, this.typingUserIds)
      : message = null,
        roomsChanged = false,
        reactionUpdate = null;
  ChatSyncEvent.reactionUpdated(
    this.roomId,
    String targetEventId,
    String emoji,
    String sender,
    String reactionEventId,
    bool removed,
  )   : message = null,
        roomsChanged = false,
        typingUserIds = null,
        reactionUpdate = ChatReactionUpdate(
          targetEventId: targetEventId,
          emoji: emoji,
          sender: sender,
          reactionEventId: reactionEventId,
          removed: removed,
        );

  final String? roomId;
  final ChatMessage? message;
  final bool roomsChanged;
  final List<String>? typingUserIds;
  final ChatReactionUpdate? reactionUpdate;
}

class ChatReactionUpdate {
  ChatReactionUpdate({
    required this.targetEventId,
    required this.emoji,
    required this.sender,
    required this.reactionEventId,
    required this.removed,
  });

  final String targetEventId;
  final String emoji;
  final String sender;
  final String reactionEventId;
  final bool removed;
}

class ChatMember {
  ChatMember({required this.userId, this.displayName});

  final String userId;
  final String? displayName;
}

class ChatReadReceipt {
  ChatReadReceipt({required this.userId, this.tsMs});

  final String userId;
  final int? tsMs;
}

class UnconfiguredChatService implements ChatService {
  UnconfiguredChatService() : _rooms = ValueNotifier(const []);

  final ValueNotifier<List<ChatRoom>> _rooms;
  final _sync = StreamController<ChatSyncEvent>.broadcast();

  @override
  bool get isConfigured => false;

  @override
  String get urlPreviewCacheKey => 'unconfigured';

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
  Future<String> sendReply(String roomId, String body, String replyToEventId) async {
    throw StateError('Chat not configured');
  }

  @override
  Future<String> sendReaction(String roomId, String eventId, String emoji) async {
    throw StateError('Chat not configured');
  }

  @override
  Future<void> redactEvent(String roomId, String eventId, {String? reason}) async {
    throw StateError('Chat not configured');
  }

  @override
  Future<void> setTyping(String roomId, bool typing) async {}

  @override
  Future<void> sendReadReceipt(String roomId, String eventId) async {}

  @override
  Future<List<ChatReadReceipt>> readReceiptsForEvent(String roomId, String eventId) async =>
      [];

  @override
  Future<ChatUrlPreview> fetchUrlPreview(String url) async {
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
  Future<String> createGroupChat(String name, List<String> userIds) async {
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

  final Map<String, Map<String, List<ChatReaction>>> _reactionsByRoom = {};

  int urlPreviewFetchCount = 0;
  Object? urlPreviewError;

  String? lastCreatedGroupName;
  List<String>? lastCreatedGroupUserIds;

  /// Local paths returned by [downloadMedia] / [downloadThumbnail] for fakes.
  final Map<String, String> mediaPaths = {};

  @override
  String get urlPreviewCacheKey => 'fake';
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
    final list = List<ChatMessage>.from(_timelines[roomId] ?? const []);
    final reactions = _reactionsByRoom[roomId] ?? {};
    return list
        .map(
          (m) => m.copyWith(reactions: reactions[m.eventId] ?? m.reactions),
        )
        .toList();
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
  Future<String> sendReply(String roomId, String body, String replyToEventId) async {
    final timeline = _timelines[roomId] ?? [];
    ChatReplyPreview? replyPreview;
    for (final m in timeline) {
      if (m.eventId == replyToEventId) {
        replyPreview = ChatReplyPreview(
          eventId: replyToEventId,
          senderId: m.senderId,
          senderDisplayName: m.senderDisplayName,
          body: m.body,
        );
        break;
      }
    }
    replyPreview ??= ChatReplyPreview(eventId: replyToEventId, senderId: '', body: '…');
    final id = await sendMessage(roomId, body);
    final idx = _timelines[roomId]!.indexWhere((m) => m.eventId == id);
    if (idx >= 0) {
      _timelines[roomId]![idx] = _timelines[roomId]![idx].copyWith(inReplyTo: replyPreview);
    }
    return id;
  }

  @override
  Future<String> sendReaction(String roomId, String eventId, String emoji) async {
    final roomReactions = _reactionsByRoom.putIfAbsent(roomId, () => {});
    final list = roomReactions.putIfAbsent(eventId, () => []);
    list.removeWhere((r) => r.userId == '@me:family.test');
    final id = 'rxn_${DateTime.now().microsecondsSinceEpoch}';
    list.add(
      ChatReaction(
        emoji: emoji,
        userId: '@me:family.test',
        reactionEventId: id,
      ),
    );
    return id;
  }

  @override
  Future<void> redactEvent(String roomId, String eventId, {String? reason}) async {
    final list = _timelines[roomId];
    if (list == null) {
      return;
    }
    _timelines[roomId] = list.where((m) => m.eventId != eventId).toList();
  }

  @override
  Future<void> setTyping(String roomId, bool typing) async {}

  @override
  Future<void> sendReadReceipt(String roomId, String eventId) async {}

  @override
  Future<List<ChatReadReceipt>> readReceiptsForEvent(String roomId, String eventId) async =>
      [];

  @override
  Future<ChatUrlPreview> fetchUrlPreview(String url) async {
    urlPreviewFetchCount++;
    if (urlPreviewError != null) {
      throw urlPreviewError!;
    }
    return ChatUrlPreview(url: url, title: 'Example', siteName: 'example.com');
  }

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
  Future<String> createGroupChat(String name, List<String> userIds) async {
    lastCreatedGroupName = name;
    lastCreatedGroupUserIds = List<String>.from(userIds);
    final title = name.trim().isNotEmpty
        ? name.trim()
        : userIds.join(', ');
    final roomId = '!grp_${DateTime.now().microsecondsSinceEpoch}:fake';
    _rooms.value = [
      ChatRoom(
        roomId: roomId,
        title: title,
        isDirect: false,
        encrypted: true,
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
  String get urlPreviewCacheKey =>
      bundle.matrixEnrollment.homeserver ??
      bundle.matrixHomeserverUrl ??
      bundle.discovery.matrixHomeserverUrl ??
      'matrix';

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
  Future<String> sendReply(String roomId, String body, String replyToEventId) async {
    try {
      return await _s.sendTextReply(
        roomId: roomId,
        body: body,
        replyToEventId: replyToEventId,
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
  Future<String> sendReaction(String roomId, String eventId, String emoji) async {
    return _s.sendReaction(roomId: roomId, eventId: eventId, emoji: emoji);
  }

  @override
  Future<void> redactEvent(String roomId, String eventId, {String? reason}) async {
    await _s.redactEvent(roomId: roomId, eventId: eventId, reason: reason);
  }

  @override
  Future<void> setTyping(String roomId, bool typing) async {
    await _s.setTyping(roomId: roomId, typing: typing);
  }

  @override
  Future<void> sendReadReceipt(String roomId, String eventId) async {
    await _s.sendReadReceipt(roomId: roomId, eventId: eventId);
  }

  @override
  Future<List<ChatReadReceipt>> readReceiptsForEvent(String roomId, String eventId) async {
    final raw = await _s.readReceiptsForEvent(roomId: roomId, eventId: eventId);
    return raw
        .map((r) => ChatReadReceipt(userId: r.userId, tsMs: r.tsMs?.toInt()))
        .toList();
  }

  @override
  Future<ChatUrlPreview> fetchUrlPreview(String url) async {
    final raw = await _s.fetchUrlPreview(url: url);
    return chatUrlPreviewFromRust(raw);
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
  Future<String> createGroupChat(String name, List<String> userIds) async {
    final cleanName = name.trim().isNotEmpty
        ? name.trim()
        : userIds
            .map((id) => id.split(':').first.replaceFirst('@', ''))
            .join(', ');
    return _s.createRoom(
      name: cleanName,
      inviteUserIds: userIds,
      encrypted: true,
    );
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
        typing: (wrapped) {
          final t = wrapped.field0;
          _sync.add(ChatSyncEvent.typing(t.roomId, t.userIds));
        },
        reactionUpdated: (wrapped) {
          _sync.add(
            ChatSyncEvent.reactionUpdated(
              wrapped.roomId,
              wrapped.targetEventId,
              wrapped.emoji,
              wrapped.sender,
              wrapped.reactionEventId,
              wrapped.removed,
            ),
          );
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
