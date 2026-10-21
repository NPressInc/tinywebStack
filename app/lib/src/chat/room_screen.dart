import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../api/models.dart';
import '../widgets/quiet_hours_banner.dart';
import 'app_media_saver.dart';
import 'chat_colors.dart';
import 'chat_message_context.dart';
import 'chat_models.dart';
import 'chat_service.dart';
import 'chat_timeline.dart';
import 'message_bubble.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({
    super.key,
    required this.roomId,
    required this.title,
    required this.chat,
    required this.profile,
    this.isGroupRoom = true,
  });

  final String roomId;
  final String title;
  final ChatService chat;
  final AppMeProfile profile;
  final bool isGroupRoom;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  final _picker = ImagePicker();
  final _bubbleKeys = <String, GlobalKey>{};
  List<ChatMessage> _messages = [];
  String? _errorBanner;
  StreamSubscription<ChatSyncEvent>? _syncSub;
  bool _loading = true;
  ChatMessage? _replyTo;
  List<String> _typingUserIds = [];
  bool _showScrollToBottom = false;
  int _unreadWhileScrolled = 0;
  Timer? _typingTimer;
  String? _deliveryLabel;

  bool get _isKid => widget.profile.role == 'kid';

  @override
  void initState() {
    super.initState();
    _composer.addListener(_onComposerChanged);
    _scroll.addListener(_onScroll);
    _load();
    _syncSub = widget.chat.syncEvents.listen(_onSync);
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    widget.chat.setTyping(widget.roomId, false);
    _syncSub?.cancel();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) {
      return;
    }
    final atBottom = _scroll.position.maxScrollExtent - _scroll.offset < 80;
    setState(() {
      _showScrollToBottom = !atBottom;
      if (atBottom) {
        _unreadWhileScrolled = 0;
      }
    });
  }

  void _onComposerChanged() {
    _typingTimer?.cancel();
    widget.chat.setTyping(widget.roomId, true);
    _typingTimer = Timer(const Duration(seconds: 3), () {
      widget.chat.setTyping(widget.roomId, false);
    });
    setState(() {});
  }

  GlobalKey _keyFor(String eventId) =>
      _bubbleKeys.putIfAbsent(eventId, () => GlobalKey());

  Future<void> _load() async {
    setState(() => _loading = true);
    _messages = await widget.chat.loadTimeline(widget.roomId);
    setState(() => _loading = false);
    _scrollToBottom();
    _markRead();
  }

  void _markRead() {
    final last = _messages.where((m) => !m.isOwn).lastOrNull;
    if (last != null) {
      widget.chat.sendReadReceipt(widget.roomId, last.eventId);
    }
  }

  void _onSync(ChatSyncEvent event) {
    if (event.roomId != widget.roomId) {
      if (event.roomsChanged) {
        return;
      }
      return;
    }
    if (event.typingUserIds != null) {
      setState(() => _typingUserIds = event.typingUserIds!);
      return;
    }
    if (event.reactionUpdate != null) {
      _applyReactionUpdate(event.reactionUpdate!);
      return;
    }
    if (event.roomsChanged) {
      return;
    }
    final msg = event.message;
    if (msg == null) {
      return;
    }
    if (_messages.any((m) => m.eventId == msg.eventId)) {
      return;
    }
    setState(() {
      _messages = [..._messages, msg];
      if (_showScrollToBottom) {
        _unreadWhileScrolled++;
      }
    });
    if (!_showScrollToBottom) {
      _scrollToBottom();
    }
    _markRead();
  }

  void _applyReactionUpdate(ChatReactionUpdate u) {
    setState(() {
      _messages = _messages.map((m) {
        if (m.eventId != u.targetEventId) {
          return m;
        }
        var reactions = [...m.reactions];
        reactions.removeWhere((r) => r.userId == u.sender);
        if (!u.removed) {
          reactions.add(
            ChatReaction(
              emoji: u.emoji,
              userId: u.sender,
              reactionEventId: u.reactionEventId,
            ),
          );
        }
        return m.copyWith(reactions: reactions);
      }).toList();
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _scrollToEvent(String eventId) {
    final index = _messages.indexWhere((m) => m.eventId == eventId);
    if (index < 0) {
      return;
    }
    final offset = index * 72.0;
    _scroll.animateTo(
      offset.clamp(0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _send() async {
    final body = _composer.text.trim();
    if (body.isEmpty) {
      return;
    }
    final reply = _replyTo;
    final replyId = reply?.eventId;
    _composer.clear();
    setState(() {
      _errorBanner = null;
      _replyTo = null;
    });
    try {
      final eventId = replyId != null
          ? await widget.chat.sendReply(widget.roomId, body, replyId)
          : await widget.chat.sendMessage(widget.roomId, body);
      if (_messages.any((m) => m.eventId == eventId)) {
        return;
      }
      final msg = ChatMessage(
        eventId: eventId,
        body: body,
        senderId: widget.profile.mxid,
        senderDisplayName: widget.profile.username,
        tsMs: DateTime.now().millisecondsSinceEpoch,
        isOwn: true,
        inReplyTo: reply == null
            ? null
            : ChatReplyPreview(
                eventId: reply.eventId,
                senderId: reply.senderId,
                senderDisplayName: reply.senderDisplayName,
                body: reply.body,
              ),
      );
      setState(() {
        _messages = [..._messages, msg];
        _deliveryLabel = 'Delivered';
      });
      _scrollToBottom();
    } on ChatSendException catch (e) {
      _showSendError(e.message);
    }
  }

  void _showSendError(String text) {
    if (text.startsWith('forbidden:')) {
      setState(() {
        _errorBanner = 'Not allowed: ${text.substring('forbidden:'.length).trim()}';
      });
    } else {
      setState(() => _errorBanner = text);
    }
  }

  Future<void> _toggleReaction(ChatMessage message, String emoji) async {
    final existing = message.reactions.where((r) => r.userId == widget.profile.mxid);
    final same = existing.where((r) => r.emoji == emoji).firstOrNull;
    if (same != null) {
      await widget.chat.redactEvent(widget.roomId, same.reactionEventId);
      setState(() {
        _messages = _messages.map((m) {
          if (m.eventId != message.eventId) {
            return m;
          }
          return m.copyWith(
            reactions: m.reactions.where((r) => r.reactionEventId != same.reactionEventId).toList(),
          );
        }).toList();
      });
      return;
    }
    for (final r in existing) {
      await widget.chat.redactEvent(widget.roomId, r.reactionEventId);
    }
    final id = await widget.chat.sendReaction(widget.roomId, message.eventId, emoji);
    setState(() {
      _messages = _messages.map((m) {
        if (m.eventId != message.eventId) {
          return m;
        }
        final reactions = m.reactions.where((r) => r.userId != widget.profile.mxid).toList();
        reactions.add(
          ChatReaction(emoji: emoji, userId: widget.profile.mxid, reactionEventId: id),
        );
        return m.copyWith(reactions: reactions);
      }).toList();
    });
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    await widget.chat.redactEvent(widget.roomId, message.eventId);
    setState(() => _messages = _messages.where((m) => m.eventId != message.eventId).toList());
  }

  Future<void> _pickAttachment(ImageSource source, {required bool video}) async {
    setState(() => _errorBanner = null);
    final caption = _composer.text.trim();
    if (caption.isNotEmpty) {
      _composer.clear();
    }
    try {
      final XFile? file = video
          ? await _picker.pickVideo(source: source)
          : await _picker.pickImage(source: source);
      if (file == null) {
        return;
      }
      final mime = video ? 'video/mp4' : _guessImageMime(file.path);
      final eventId = await widget.chat.sendMedia(
        widget.roomId,
        file.path,
        mime,
        caption: caption.isEmpty ? null : caption,
      );
      if (_messages.any((m) => m.eventId == eventId)) {
        return;
      }
      final name = file.name;
      final body = caption.isNotEmpty ? caption : '[$name]';
      final msg = ChatMessage(
        eventId: eventId,
        body: body,
        senderId: widget.profile.mxid,
        senderDisplayName: widget.profile.username,
        tsMs: DateTime.now().millisecondsSinceEpoch,
        isOwn: true,
        msgtype: video ? 'm.video' : 'm.image',
        filename: name,
        mimeType: mime,
      );
      setState(() => _messages = [..._messages, msg]);
      _scrollToBottom();
    } on ChatSendException catch (e) {
      _showSendError(e.message);
    } catch (e) {
      setState(() => _errorBanner = e.toString());
    }
  }

  String _guessImageMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Future<void> _showAttachSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photos'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAttachment(ImageSource.gallery, video: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAttachment(ImageSource.camera, video: false);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openContextMenu(ChatMessage message) {
    HapticFeedback.mediumImpact();
    showMessageContextOverlay(
      context: context,
      message: message,
      roomId: widget.roomId,
      chat: widget.chat,
      ownUserId: widget.profile.mxid,
      bubbleKey: _keyFor(message.eventId),
      mediaSaver: appMediaSaver,
      onReply: () => setState(() => _replyTo = message),
      onReaction: (emoji) => _toggleReaction(message, emoji),
      onDelete: () => _deleteMessage(message),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = buildTimelineRows(_messages, isGroupRoom: widget.isGroupRoom);
    final hasText = _composer.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          if (_isKid && widget.profile.quietHours.active)
            QuietHoursBanner(profile: widget.profile, isKid: true),
          if (_errorBanner != null)
            MaterialBanner(
              content: Text(_errorBanner!),
              leading: const Icon(Icons.error_outline, color: Colors.red),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _errorBanner = null),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          Expanded(
            child: Stack(
              children: [
                _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: rows.length + (_typingUserIds.isNotEmpty ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == rows.length) {
                            return const _TypingBubble();
                          }
                          final row = rows[index];
                          if (row is TimelineDateHeader) {
                            return Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Text(
                                  row.label,
                                  style: Theme.of(context).textTheme.labelMedium,
                                ),
                              ),
                            );
                          }
                          final r = row as TimelineMessageRow;
                          final m = r.message;
                          return MessageBubble(
                            message: m,
                            roomId: widget.roomId,
                            chat: widget.chat,
                            mediaSaver: appMediaSaver,
                            showSenderName: r.showSenderName,
                            isLastInGroup: r.isLastInGroup,
                            isFirstInGroup: r.isFirstInGroup,
                            bubbleKey: _keyFor(m.eventId),
                            onLongPress: () => _openContextMenu(m),
                            onDoubleTap: () => _toggleReaction(m, '❤️'),
                            onSwipeReply: () => setState(() => _replyTo = m),
                            onReplyQuoteTap: _scrollToEvent,
                            onReactionStackTap: (emoji, reactors) {
                              showDialog<void>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: Text(emoji),
                                  content: Text(reactors.map((r) => r.userId).join('\n')),
                                ),
                              );
                            },
                          );
                        },
                      ),
                if (_showScrollToBottom)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: FloatingActionButton.small(
                      onPressed: () {
                        _scrollToBottom();
                        setState(() => _unreadWhileScrolled = 0);
                      },
                      child: Badge(
                        isLabelVisible: _unreadWhileScrolled > 0,
                        label: Text('$_unreadWhileScrolled'),
                        child: const Icon(Icons.arrow_downward),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_deliveryLabel != null && _messages.any((m) => m.isOwn))
            Padding(
              padding: const EdgeInsets.only(right: 16, bottom: 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  _deliveryLabel!,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          if (_replyTo != null)
            Material(
              color: Colors.black12,
              child: ListTile(
                dense: true,
                title: Text('Replying to ${_replyTo!.senderLabel}'),
                subtitle: Text(_replyTo!.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _replyTo = null),
                ),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: _showAttachSheet,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      decoration: InputDecoration(
                        hintText: 'Message',
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  if (hasText)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Material(
                        color: const Color(0xFF0A84FF),
                        shape: const CircleBorder(),
                        child: IconButton(
                          icon: const Icon(Icons.arrow_upward, color: Colors.white),
                          onPressed: _send,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: ChatColors.typingBubble(context),
          borderRadius: BorderRadius.circular(18),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final phase = (_controller.value + i * 0.2) % 1.0;
                final dy = (phase < 0.5 ? phase : 1 - phase) * 6;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Transform.translate(
                    offset: Offset(0, -dy),
                    child: const Icon(Icons.circle, size: 6, color: Colors.grey),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}
