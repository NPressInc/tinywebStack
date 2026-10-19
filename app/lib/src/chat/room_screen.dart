import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../brand.dart';
import '../widgets/quiet_hours_banner.dart';
import 'chat_models.dart';
import 'chat_service.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({
    super.key,
    required this.roomId,
    required this.title,
    required this.chat,
    required this.profile,
  });

  final String roomId;
  final String title;
  final ChatService chat;
  final AppMeProfile profile;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage> _messages = [];
  String? _errorBanner;
  StreamSubscription<ChatSyncEvent>? _syncSub;
  bool _loading = true;

  bool get _isKid => widget.profile.role == 'kid';

  @override
  void initState() {
    super.initState();
    _load();
    _syncSub = widget.chat.syncEvents.listen(_onSync);
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    _messages = await widget.chat.loadTimeline(widget.roomId);
    setState(() => _loading = false);
    _scrollToBottom();
  }

  void _onSync(ChatSyncEvent event) {
    if (event.roomsChanged) {
      return;
    }
    final msg = event.message;
    if (msg == null || event.roomId != widget.roomId) {
      return;
    }
    if (_messages.any((m) => m.eventId == msg.eventId)) {
      return;
    }
    setState(() {
      _messages = [..._messages, msg];
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final body = _composer.text.trim();
    if (body.isEmpty) {
      return;
    }
    _composer.clear();
    setState(() => _errorBanner = null);
    try {
      final eventId = await widget.chat.sendMessage(widget.roomId, body);
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
      );
      setState(() => _messages = [..._messages, msg]);
      _scrollToBottom();
    } on ChatSendException catch (e) {
      final text = e.message;
      if (text.startsWith('forbidden:')) {
        setState(() {
          _errorBanner = 'Not allowed: ${text.substring('forbidden:'.length).trim()}';
        });
      } else {
        setState(() => _errorBanner = text);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final m = _messages[index];
                      return _MessageBubble(message: m);
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      decoration: const InputDecoration(
                        hintText: 'Message',
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    color: TinyWebColors.blueDeep,
                    onPressed: _send,
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

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final time = DateTime.fromMillisecondsSinceEpoch(message.tsMs);
    final timeLabel =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    final align = message.isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final color = message.isOwn ? TinyWebColors.blueDeep : Colors.white;
    final textColor = message.isOwn ? Colors.white : TinyWebColors.text;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: align,
        children: [
          if (!message.isOwn)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                message.senderLabel,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.78,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
              border: message.isOwn
                  ? null
                  : Border.all(color: TinyWebColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message.body, style: TextStyle(color: textColor)),
                const SizedBox(height: 4),
                Text(
                  timeLabel,
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.75),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
