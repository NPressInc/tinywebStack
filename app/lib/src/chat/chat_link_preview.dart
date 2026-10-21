import 'dart:async';

import 'package:flutter/material.dart';

import 'chat_linkify.dart';
import 'chat_models.dart';
import 'chat_service.dart';

final _previewCache = <String, ChatUrlPreview?>{};
final _homeserverPreviewDisabled = <String>{};
final _urlPreviewInflight = <String, Future<ChatUrlPreview?>>{};
final _scopePreviewChain = <String, Future<void>>{};

/// Clears in-memory preview caches (tests).
void clearUrlPreviewCaches() {
  _previewCache.clear();
  _homeserverPreviewDisabled.clear();
  _urlPreviewInflight.clear();
  _scopePreviewChain.clear();
}

Future<T> _runSerializedForScope<T>(String scope, Future<T> Function() action) async {
  final previous = _scopePreviewChain[scope] ?? Future<void>.value();
  final gate = Completer<void>();
  _scopePreviewChain[scope] = gate.future;
  await previous;
  try {
    return await action();
  } finally {
    gate.complete();
    if (_scopePreviewChain[scope] == gate.future) {
      _scopePreviewChain.remove(scope);
    }
  }
}

bool isUrlPreviewResolved(String url) => _previewCache.containsKey(url);

ChatUrlPreview? cachedUrlPreview(String url) => _previewCache[url];

bool urlPreviewUnavailableError(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('url_preview_unavailable') ||
      text.contains('m_unrecognized') ||
      (text.contains('preview_url') &&
          (text.contains('403') || text.contains('404') || text.contains('forbidden')));
}

Future<ChatUrlPreview?> loadUrlPreview(ChatService chat, String url) async {
  final scope = chat.urlPreviewCacheKey;
  if (_homeserverPreviewDisabled.contains(scope)) {
    return null;
  }
  if (_previewCache.containsKey(url)) {
    return _previewCache[url];
  }
  final inflight = _urlPreviewInflight[url];
  if (inflight != null) {
    return inflight;
  }
  final future = _runSerializedForScope(scope, () => _fetchAndCachePreview(chat, scope, url));
  _urlPreviewInflight[url] = future;
  try {
    return await future;
  } finally {
    _urlPreviewInflight.remove(url);
  }
}

Future<ChatUrlPreview?> _fetchAndCachePreview(
  ChatService chat,
  String scope,
  String url,
) async {
  if (_homeserverPreviewDisabled.contains(scope)) {
    return null;
  }
  if (_previewCache.containsKey(url)) {
    return _previewCache[url];
  }
  try {
    final preview = await chat.fetchUrlPreview(url);
    final empty = preview.title == null &&
        preview.siteName == null &&
        preview.description == null &&
        preview.imageMxc == null;
    if (empty) {
      _previewCache[url] = null;
      return null;
    }
    _previewCache[url] = preview;
    return preview;
  } catch (e) {
    if (urlPreviewUnavailableError(e)) {
      _homeserverPreviewDisabled.add(scope);
    }
    _previewCache[url] = null;
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
