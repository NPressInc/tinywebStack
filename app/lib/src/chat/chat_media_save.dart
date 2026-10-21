import 'package:flutter/material.dart';

import 'chat_service.dart';
import 'media_saver.dart';

String mediaSaveFailureMessage(Object error) {
  if (error is MediaSavePermissionDenied) {
    return error.message;
  }
  return error.toString();
}

Future<void> saveChatMediaToPhotos({
  required BuildContext context,
  required ChatService chat,
  required MediaSaver mediaSaver,
  required String roomId,
  required String eventId,
  required bool isVideo,
}) async {
  try {
    final path = await chat.downloadMedia(roomId, eventId);
    if (isVideo) {
      await mediaSaver.saveVideo(path);
    } else {
      await mediaSaver.saveImage(path);
    }
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved to Photos')),
    );
  } catch (e) {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Couldn't save: ${mediaSaveFailureMessage(e)}")),
    );
  }
}
