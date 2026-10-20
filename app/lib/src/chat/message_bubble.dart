import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../brand.dart';
import 'chat_linkify.dart';
import 'chat_models.dart';
import 'chat_service.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.roomId,
    required this.chat,
  });

  final ChatMessage message;
  final String roomId;
  final ChatService chat;

  @override
  Widget build(BuildContext context) {
    final time = DateTime.fromMillisecondsSinceEpoch(message.tsMs);
    final timeLabel =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    final align = message.isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final utd = message.utd;
    final color = utd
        ? Colors.grey.shade200
        : (message.isOwn ? TinyWebColors.blueDeep : Colors.white);
    final textColor = utd
        ? Colors.grey.shade700
        : (message.isOwn ? Colors.white : TinyWebColors.text);
    final linkColor = message.isOwn ? Colors.white : TinyWebColors.blueDeep;

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
                if (utd)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_outline, size: 14, color: textColor),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          message.body,
                          style: TextStyle(
                            color: textColor,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    ],
                  )
                else if (message.isImage)
                  _ImageMessageBody(
                    message: message,
                    roomId: roomId,
                    chat: chat,
                    textColor: textColor,
                    linkColor: linkColor,
                  )
                else if (message.isVideo)
                  _VideoMessageBody(
                    message: message,
                    roomId: roomId,
                    chat: chat,
                    textColor: textColor,
                    linkColor: linkColor,
                  )
                else
                  ChatLinkifyText(
                    text: message.body,
                    style: TextStyle(color: textColor),
                    linkColor: linkColor,
                  ),
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

class _ImageMessageBody extends StatefulWidget {
  const _ImageMessageBody({
    required this.message,
    required this.roomId,
    required this.chat,
    required this.textColor,
    required this.linkColor,
  });

  final ChatMessage message;
  final String roomId;
  final ChatService chat;
  final Color textColor;
  final Color linkColor;

  @override
  State<_ImageMessageBody> createState() => _ImageMessageBodyState();
}

class _ImageMessageBodyState extends State<_ImageMessageBody> {
  String? _path;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final path = await widget.chat.downloadMedia(
        widget.roomId,
        widget.message.eventId,
      );
      if (!mounted) return;
      setState(() {
        _path = path;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _openFullScreen() {
    final path = _path;
    if (path == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black),
          body: Center(
            child: InteractiveViewer(
              child: Image.file(File(path), fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final caption = widget.message.mediaCaption;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading)
          const SizedBox(
            height: 120,
            width: 200,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (_error != null)
          Text('Could not load image', style: TextStyle(color: widget.textColor))
        else if (_path != null)
          GestureDetector(
            onTap: _openFullScreen,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(_path!),
                width: 220,
                fit: BoxFit.cover,
              ),
            ),
          ),
        if (caption != null && caption.isNotEmpty) ...[
          const SizedBox(height: 6),
          ChatLinkifyText(
            text: caption,
            style: TextStyle(color: widget.textColor),
            linkColor: widget.linkColor,
          ),
        ],
      ],
    );
  }
}

class _VideoMessageBody extends StatefulWidget {
  const _VideoMessageBody({
    required this.message,
    required this.roomId,
    required this.chat,
    required this.textColor,
    required this.linkColor,
  });

  final ChatMessage message;
  final String roomId;
  final ChatService chat;
  final Color textColor;
  final Color linkColor;

  @override
  State<_VideoMessageBody> createState() => _VideoMessageBodyState();
}

class _VideoMessageBodyState extends State<_VideoMessageBody> {
  VideoPlayerController? _controller;
  String? _thumbPath;
  String? _videoPath;
  String? _error;
  bool _loading = true;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final thumb = await widget.chat.downloadThumbnail(
        widget.roomId,
        widget.message.eventId,
      );
      if (!mounted) return;
      setState(() {
        _thumbPath = thumb;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _controller?.pause();
      setState(() => _playing = false);
      return;
    }
    try {
      _videoPath ??= await widget.chat.downloadMedia(
        widget.roomId,
        widget.message.eventId,
      );
      _controller ??= VideoPlayerController.file(File(_videoPath!));
      await _controller!.initialize();
      await _controller!.play();
      if (!mounted) return;
      setState(() => _playing = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final caption = widget.message.mediaCaption;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: _togglePlay,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (_playing && _controller != null && _controller!.value.isInitialized)
                SizedBox(
                  width: 220,
                  child: AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio,
                    child: VideoPlayer(_controller!),
                  ),
                )
              else if (_loading)
                const SizedBox(
                  height: 120,
                  width: 200,
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else if (_thumbPath != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(_thumbPath!),
                    width: 220,
                    fit: BoxFit.cover,
                  ),
                )
              else
                Container(
                  width: 220,
                  height: 120,
                  alignment: Alignment.center,
                  color: Colors.black26,
                  child: Icon(Icons.videocam, color: widget.textColor, size: 40),
                ),
              if (!_playing)
                Icon(Icons.play_circle_fill, color: Colors.white.withValues(alpha: 0.9), size: 48),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Could not play video', style: TextStyle(color: widget.textColor)),
          ),
        if (caption != null && caption.isNotEmpty) ...[
          const SizedBox(height: 6),
          ChatLinkifyText(
            text: caption,
            style: TextStyle(color: widget.textColor),
            linkColor: widget.linkColor,
          ),
        ],
      ],
    );
  }
}
