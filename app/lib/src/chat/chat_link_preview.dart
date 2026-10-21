import 'package:flutter/material.dart';

import 'chat_linkify.dart';
import 'chat_models.dart';
import 'chat_service.dart';

final _previewCache = <String, ChatUrlPreview>{};

ChatUrlPreview? cachedUrlPreview(String url) => _previewCache[url];

Future<ChatUrlPreview?> loadUrlPreview(ChatService chat, String url) async {
  final hit = _previewCache[url];
  if (hit != null) {
    return hit;
  }
  try {
    final preview = await chat.fetchUrlPreview(url);
    _previewCache[url] = preview;
    return preview;
  } catch (_) {
    return null;
  }
}

class ChatLinkPreviewCard extends StatelessWidget {
  const ChatLinkPreviewCard({
    super.key,
    required this.preview,
    required this.onTap,
    this.compact = false,
  });

  final ChatUrlPreview preview;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final title = preview.title ?? preview.siteName ?? preview.url;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: EdgeInsets.only(top: compact ? 4 : 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              if (preview.siteName != null && preview.title != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    preview.siteName!,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

void openPreviewUrl(ChatUrlPreview preview) {
  openExternalUrl(preview.url);
}
