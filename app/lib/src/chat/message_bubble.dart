import 'dart:io';

import 'package:flutter/material.dart';

import 'chat_colors.dart';
import 'chat_fullscreen_media.dart';
import 'chat_link_preview.dart';
import 'chat_linkify.dart';
import 'chat_models.dart';
import 'chat_reactions.dart';
import 'chat_service.dart';
import 'media_save_button.dart';
import 'media_saver.dart';

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.roomId,
    required this.chat,
    this.mediaSaver,
    this.previewMedia = true,
    this.showSenderName = true,
    this.showTimestamp = true,
    this.isLastInGroup = true,
    this.isFirstInGroup = true,
    this.elevated = false,
    this.bubbleKey,
    this.onLongPress,
    this.onDoubleTap,
    this.onSwipeReply,
    this.onReplyQuoteTap,
    this.onReactionStackTap,
  });

  final ChatMessage message;
  final String roomId;
  final ChatService chat;
  final MediaSaver? mediaSaver;
  final bool showSenderName;
  final bool showTimestamp;
  final bool isLastInGroup;
  final bool isFirstInGroup;
  final bool elevated;
  final GlobalKey? bubbleKey;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onSwipeReply;
  final void Function(String eventId)? onReplyQuoteTap;
  final void Function(String emoji, List<ChatReaction> reactors)? onReactionStackTap;

  /// When false, skips decoding media in the bubble (widget tests).
  final bool previewMedia;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  double _dragX = 0;
  double _timestampDrag = 0;
  ChatUrlPreview? _linkPreview;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  @override
  void didUpdateWidget(covariant MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.eventId != widget.message.eventId ||
        oldWidget.message.body != widget.message.body) {
      _loadPreview();
    }
  }

  Future<void> _loadPreview() async {
    final url = widget.message.firstUrl;
    if (url == null) {
      return;
    }
    if (isUrlPreviewResolved(url)) {
      setState(() => _linkPreview = cachedUrlPreview(url));
      return;
    }
    final preview = await loadUrlPreview(widget.chat, url);
    if (!mounted) {
      return;
    }
    setState(() => _linkPreview = preview);
  }

  BorderRadius _bubbleRadius() {
    const r = 18.0;
    const t = 4.0;
    if (widget.message.isOwn) {
      return BorderRadius.only(
        topLeft: const Radius.circular(r),
        topRight: Radius.circular(widget.isFirstInGroup ? r : t),
        bottomLeft: const Radius.circular(r),
        bottomRight: Radius.circular(widget.isLastInGroup ? r : t),
      );
    }
    return BorderRadius.only(
      topLeft: Radius.circular(widget.isFirstInGroup ? r : t),
      topRight: const Radius.circular(r),
      bottomLeft: Radius.circular(widget.isLastInGroup ? r : t),
      bottomRight: const Radius.circular(r),
    );
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final time = DateTime.fromMillisecondsSinceEpoch(message.tsMs);
    final timeLabel =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    final align = message.isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final utd = message.utd;
    final color = utd
        ? Colors.grey.shade200
        : (message.isOwn ? ChatColors.ownBubble : ChatColors.otherBubble(context));
    final textColor = utd
        ? Colors.grey.shade700
        : (message.isOwn ? ChatColors.ownText : ChatColors.otherText(context));
    final linkColor = message.isOwn ? Colors.white : ChatColors.ownBubble;
    final showMediaSave = !utd && message.isMedia && widget.mediaSaver != null;

    final bubble = Container(
      key: widget.bubbleKey ??
          (showMediaSave ? ValueKey('chat-bubble-${message.eventId}') : null),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.78,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: _bubbleRadius(),
        boxShadow: widget.elevated
            ? [BoxShadow(color: Colors.black26, blurRadius: 12, offset: const Offset(0, 4))]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.inReplyTo != null)
            GestureDetector(
              onTap: () => widget.onReplyQuoteTap?.call(message.inReplyTo!.eventId),
              child: Container(
                key: const Key('reply-quote'),
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  message.inReplyTo!.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: textColor.withValues(alpha: 0.9), fontSize: 12),
                ),
              ),
            ),
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
              roomId: widget.roomId,
              chat: widget.chat,
              textColor: textColor,
              linkColor: linkColor,
              mediaSaver: widget.mediaSaver,
              previewMedia: widget.previewMedia,
            )
          else if (message.isVideo)
            _VideoMessageBody(
              message: message,
              roomId: widget.roomId,
              chat: widget.chat,
              textColor: textColor,
              linkColor: linkColor,
              mediaSaver: widget.mediaSaver,
              previewMedia: widget.previewMedia,
            )
          else
            ChatLinkifyText(
              text: message.body,
              style: TextStyle(color: textColor),
              linkColor: linkColor,
            ),
          if (_linkPreview != null)
            ChatLinkPreviewCard(
              preview: _linkPreview!,
              onTap: () => openPreviewUrl(_linkPreview!),
            ),
          if (widget.showTimestamp) ...[
            const SizedBox(height: 4),
            Text(
              timeLabel,
              style: TextStyle(
                color: textColor.withValues(alpha: 0.75),
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );

    final bubbleWithReactions = Stack(
      clipBehavior: Clip.none,
      children: [
        bubble,
        ReactionStacks(
          reactions: message.reactions,
          isOwn: message.isOwn,
          onTapStack: widget.onReactionStackTap,
        ),
      ],
    );

    final interactive = GestureDetector(
      onLongPress: widget.onLongPress,
      onDoubleTap: widget.onDoubleTap,
      onHorizontalDragUpdate: (d) {
        setState(() {
          _dragX += d.delta.dx;
          _timestampDrag += d.delta.dx;
        });
      },
      onHorizontalDragEnd: (_) {
        if (_dragX > 48) {
          widget.onSwipeReply?.call();
        }
        setState(() {
          _dragX = 0;
          _timestampDrag = 0;
        });
      },
      child: Transform.translate(
        offset: Offset(_dragX.clamp(-80.0, 80.0), 0),
        child: bubbleWithReactions,
      ),
    );

    final verticalPad = widget.isLastInGroup ? 4.0 : 1.0;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPad),
      child: Column(
        crossAxisAlignment: align,
        children: [
          if (widget.showSenderName && !message.isOwn)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                message.senderLabel,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (message.isOwn) const Spacer(),
              if (_timestampDrag < -8)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    timeLabel,
                    key: const Key('edge-timestamp'),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              if (showMediaSave && message.isOwn)
                MediaSaveButton(
                  key: ValueKey('media-save-${message.eventId}'),
                  eventId: message.eventId,
                  roomId: widget.roomId,
                  chat: widget.chat,
                  isVideo: message.isVideo,
                  mediaSaver: widget.mediaSaver!,
                ),
              if (_dragX > 12)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.reply, size: 18, color: ChatColors.ownBubble),
                ),
              interactive,
              if (showMediaSave && !message.isOwn)
                MediaSaveButton(
                  key: ValueKey('media-save-${message.eventId}'),
                  eventId: message.eventId,
                  roomId: widget.roomId,
                  chat: widget.chat,
                  isVideo: message.isVideo,
                  mediaSaver: widget.mediaSaver!,
                ),
              if (!message.isOwn) const Spacer(),
            ],
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
    this.mediaSaver,
    this.previewMedia = true,
  });

  final ChatMessage message;
  final String roomId;
  final ChatService chat;
  final Color textColor;
  final Color linkColor;
  final MediaSaver? mediaSaver;
  final bool previewMedia;

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
    if (!widget.previewMedia) {
      _loading = false;
      return;
    }
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
        builder: (_) => ChatFullscreenImagePage(
          imagePath: path,
          eventId: widget.message.eventId,
          roomId: widget.roomId,
          chat: widget.chat,
          mediaSaver: widget.mediaSaver!,
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
    this.mediaSaver,
    this.previewMedia = true,
  });

  final ChatMessage message;
  final String roomId;
  final ChatService chat;
  final Color textColor;
  final Color linkColor;
  final MediaSaver? mediaSaver;
  final bool previewMedia;

  @override
  State<_VideoMessageBody> createState() => _VideoMessageBodyState();
}

class _VideoMessageBodyState extends State<_VideoMessageBody> {
  String? _thumbPath;
  String? _error;
  bool _loading = true;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    if (!widget.previewMedia) {
      _loading = false;
      return;
    }
    _load();
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

  Future<void> _openFullscreen() async {
    if (_opening) {
      return;
    }
    setState(() => _opening = true);
    try {
      final videoPath = await widget.chat.downloadMedia(
        widget.roomId,
        widget.message.eventId,
      );
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatFullscreenVideoPage(
            eventId: widget.message.eventId,
            roomId: widget.roomId,
            chat: widget.chat,
            videoPath: videoPath,
            mediaSaver: widget.mediaSaver!,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final caption = widget.message.mediaCaption;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: widget.mediaSaver != null ? _openFullscreen : null,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (_loading || _opening)
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
              if (!_loading && !_opening)
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
