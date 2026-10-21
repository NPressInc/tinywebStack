import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_media_save.dart';
import 'chat_models.dart';
import 'chat_reactions.dart';
import 'chat_service.dart';
import 'media_saver.dart';
import 'message_bubble.dart';

Future<void> showMessageContextOverlay({
  required BuildContext context,
  required ChatMessage message,
  required String roomId,
  required ChatService chat,
  required String ownUserId,
  required GlobalKey bubbleKey,
  MediaSaver? mediaSaver,
  void Function()? onReply,
  void Function(String emoji)? onReaction,
  void Function()? onDelete,
}) async {
  final box = bubbleKey.currentContext?.findRenderObject() as RenderBox?;
  if (box == null) {
    return;
  }
  final offset = box.localToGlobal(Offset.zero);
  final size = box.size;

  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.35),
    pageBuilder: (ctx, _, __) {
      return Stack(
        children: [
          Positioned(
            left: offset.dx,
            top: offset.dy - 52,
            width: size.width,
            child: Material(
              color: Colors.transparent,
              child: Column(
                crossAxisAlignment:
                    message.isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  _TapbackRow(
                    onPick: (emoji) {
                      Navigator.pop(ctx);
                      onReaction?.call(emoji);
                    },
                  ),
                  const SizedBox(height: 8),
                  MessageBubble(
                    message: message,
                    roomId: roomId,
                    chat: chat,
                    mediaSaver: mediaSaver,
                    previewMedia: false,
                    showTimestamp: false,
                    elevated: true,
                  ),
                  const SizedBox(height: 8),
                  _ActionMenu(
                    message: message,
                    onReply: () {
                      Navigator.pop(ctx);
                      onReply?.call();
                    },
                    onCopy: () async {
                      await Clipboard.setData(ClipboardData(text: message.body));
                      Navigator.pop(ctx);
                    },
                    onSave: mediaSaver != null && message.isMedia
                        ? () async {
                            Navigator.pop(ctx);
                            await saveChatMediaToPhotos(
                              context: context,
                              chat: chat,
                              mediaSaver: mediaSaver,
                              roomId: roomId,
                              eventId: message.eventId,
                              isVideo: message.isVideo,
                            );
                          }
                        : null,
                    onDelete: message.isOwn
                        ? () {
                            Navigator.pop(ctx);
                            onDelete?.call();
                          }
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _TapbackRow extends StatelessWidget {
  const _TapbackRow({required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('tapback-row'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(24),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in kTapbackEmojis)
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => onPick(e),
                icon: Text(e, style: const TextStyle(fontSize: 22)),
              ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => onPick('😀'),
              icon: const Icon(Icons.add_circle_outline, size: 22),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionMenu extends StatelessWidget {
  const _ActionMenu({
    required this.message,
    required this.onReply,
    required this.onCopy,
    this.onSave,
    this.onDelete,
  });

  final ChatMessage message;
  final VoidCallback onReply;
  final VoidCallback onCopy;
  final VoidCallback? onSave;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('message-action-menu'),
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        width: 220,
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            title: const Text('Reply'),
            onTap: onReply,
          ),
          if (!message.isMedia)
            ListTile(
              dense: true,
              title: const Text('Copy'),
              onTap: onCopy,
            ),
          if (onSave != null)
            ListTile(
              dense: true,
              title: const Text('Save'),
              onTap: onSave,
            ),
          if (onDelete != null)
            ListTile(
              dense: true,
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: onDelete,
            ),
        ],
      ),
      ),
    );
  }
}
