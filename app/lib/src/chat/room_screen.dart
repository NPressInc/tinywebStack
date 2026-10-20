import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api/models.dart';
import '../brand.dart';
import '../widgets/quiet_hours_banner.dart';
import 'chat_models.dart';
import 'chat_service.dart';
import 'message_bubble.dart';

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
  final _picker = ImagePicker();
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
              title: const Text('Photo from gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAttachment(ImageSource.gallery, video: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Video from gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAttachment(ImageSource.gallery, video: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAttachment(ImageSource.camera, video: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Record video'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAttachment(ImageSource.camera, video: true);
              },
            ),
          ],
        ),
      ),
    );
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
                      return MessageBubble(
                        message: m,
                        roomId: widget.roomId,
                        chat: widget.chat,
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    onPressed: _showAttachSheet,
                  ),
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
