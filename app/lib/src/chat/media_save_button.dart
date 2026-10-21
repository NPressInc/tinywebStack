import 'package:flutter/material.dart';

import '../brand.dart';
import 'chat_media_save.dart';
import 'chat_service.dart';
import 'media_saver.dart';

class MediaSaveButton extends StatefulWidget {
  const MediaSaveButton({
    super.key,
    required this.eventId,
    required this.roomId,
    required this.chat,
    required this.isVideo,
    required this.mediaSaver,
  });

  final String eventId;
  final String roomId;
  final ChatService chat;
  final bool isVideo;
  final MediaSaver mediaSaver;

  @override
  State<MediaSaveButton> createState() => _MediaSaveButtonState();
}

class _MediaSaveButtonState extends State<MediaSaveButton> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    await saveChatMediaToPhotos(
      context: context,
      chat: widget.chat,
      mediaSaver: widget.mediaSaver,
      roomId: widget.roomId,
      eventId: widget.eventId,
      isVideo: widget.isVideo,
    );
    if (mounted) {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Save to Photos',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _saving ? null : _save,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      Icons.download_rounded,
                      size: 22,
                      color: TinyWebColors.text.withValues(alpha: 0.65),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
