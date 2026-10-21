import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:tinyweb/src/chat/chat_fullscreen_media.dart';
import 'package:tinyweb/src/chat/chat_media_save.dart';
import 'package:tinyweb/src/chat/chat_models.dart';
import 'package:tinyweb/src/chat/chat_service.dart';
import 'package:tinyweb/src/chat/media_saver.dart';
import 'package:tinyweb/src/chat/message_bubble.dart';

class FakeMediaSaver implements MediaSaver {
  FakeMediaSaver({this.delay, this.error});

  final Duration? delay;
  final Object? error;
  int imageSaves = 0;
  int videoSaves = 0;
  String? lastPath;

  @override
  Future<void> saveImage(String filePath) async {
    lastPath = filePath;
    if (delay != null) {
      await Future<void>.delayed(delay!);
    }
    if (error != null) {
      throw error!;
    }
    imageSaves++;
  }

  @override
  Future<void> saveVideo(String filePath) async {
    lastPath = filePath;
    if (delay != null) {
      await Future<void>.delayed(delay!);
    }
    if (error != null) {
      throw error!;
    }
    videoSaves++;
  }
}

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  int _nextId = 0;
  final Map<int, StreamController<VideoEvent>> _streams = {};

  @override
  Future<int?> create(DataSource dataSource) async {
    final id = _nextId++;
    final stream = StreamController<VideoEvent>();
    _streams[id] = stream;
    stream.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: const Size(100, 100),
        duration: const Duration(seconds: 1),
      ),
    );
    return id;
  }

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<void> init() async {}

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      _streams[playerId]!.stream;

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Widget buildView(int playerId) => const SizedBox();

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
}

Future<void> _pumpMediaBubble(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

ChatMessage _imageMessage({required String eventId, required bool isOwn}) {
  return ChatMessage(
    eventId: eventId,
    body: '[dot.png]',
    senderId: isOwn ? '@me:family.test' : '@bob:family.test',
    tsMs: 1,
    isOwn: isOwn,
    msgtype: 'm.image',
    filename: 'dot.png',
    mimeType: 'image/png',
  );
}

void main() {
  testWidgets('MessageBubble loads image media via chat service', (tester) async {
    final chat = FakeChatService();
    const eventId = 'evt_img';
    final message = _imageMessage(eventId: eventId, isOwn: false);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            roomId: '!r1',
            chat: chat,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Could not load image'), findsOneWidget);
    await chat.dispose();
  });

  testWidgets('MessageBubble shows video poster and play affordance', (tester) async {
    final chat = FakeChatService();
    const eventId = 'evt_vid';
    chat.thumbnailPaths[eventId] = '/tmp/not-used.png';
    chat.mediaPaths[eventId] = '/tmp/not-used.mp4';
    final message = ChatMessage(
      eventId: eventId,
      body: 'clip',
      senderId: '@bob:family.test',
      tsMs: 1,
      isOwn: false,
      msgtype: 'm.video',
      filename: 'clip.mp4',
      mimeType: 'video/mp4',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            roomId: '!r1',
            chat: chat,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(find.text('clip'), findsOneWidget);
    await chat.dispose();
  });

  testWidgets('save button is left of own image bubble and right of others', (tester) async {
    final chat = FakeChatService();
    // Omit media paths so bubbles render without Image.file decode (hangs in widget tests).
    const ownId = 'evt_own';
    const otherId = 'evt_other';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MessageBubble(
                message: _imageMessage(eventId: ownId, isOwn: true),
                roomId: '!r1',
                chat: chat,
                mediaSaver: FakeMediaSaver(),
                previewMedia: false,
              ),
              MessageBubble(
                message: _imageMessage(eventId: otherId, isOwn: false),
                roomId: '!r1',
                chat: chat,
                mediaSaver: FakeMediaSaver(),
                previewMedia: false,
              ),
            ],
          ),
        ),
      ),
    );
    await _pumpMediaBubble(tester);

    final ownSave = tester.getCenter(find.byKey(const ValueKey('media-save-$ownId')));
    final ownBubble = tester.getCenter(find.byKey(const ValueKey('chat-bubble-$ownId')));
    expect(ownSave.dx, lessThan(ownBubble.dx));

    final otherSave = tester.getCenter(find.byKey(const ValueKey('media-save-$otherId')));
    final otherBubble = tester.getCenter(find.byKey(const ValueKey('chat-bubble-$otherId')));
    expect(otherSave.dx, greaterThan(otherBubble.dx));

    await chat.dispose();
  });

  testWidgets('save button shows progress while saving', (tester) async {
    final chat = FakeChatService();
    const eventId = 'evt_save_ok';
    chat.mediaPaths[eventId] = '/tmp/fake.mp4';
    final mediaSaver = FakeMediaSaver(delay: const Duration(milliseconds: 400));
    final message = ChatMessage(
      eventId: eventId,
      body: 'clip',
      senderId: '@bob:family.test',
      tsMs: 1,
      isOwn: false,
      msgtype: 'm.video',
      filename: 'clip.mp4',
      mimeType: 'video/mp4',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            roomId: '!r1',
            chat: chat,
            mediaSaver: mediaSaver,
            previewMedia: false,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('media-save-$eventId')));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 500));
    await chat.dispose();
  });

  testWidgets('save success snackbar', (tester) async {
    final chat = FakeChatService();
    chat.mediaPaths['evt_save_ok'] = '/tmp/ok.png';

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                await saveChatMediaToPhotos(
                  context: context,
                  chat: chat,
                  mediaSaver: FakeMediaSaver(),
                  roomId: '!r1',
                  eventId: 'evt_save_ok',
                  isVideo: false,
                );
              },
              child: const Text('save ok'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('save ok'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Saved to Photos'), findsOneWidget);
    await chat.dispose();
  });

  testWidgets('save failure snackbar', (tester) async {
    final chat = FakeChatService();
    chat.mediaPaths['evt_save_fail'] = '/tmp/fail.png';

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                await saveChatMediaToPhotos(
                  context: context,
                  chat: chat,
                  mediaSaver: FakeMediaSaver(error: MediaSavePermissionDenied()),
                  roomId: '!r1',
                  eventId: 'evt_save_fail',
                  isVideo: false,
                );
              },
              child: const Text('save fail'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('save fail'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.text("Couldn't save: Photo library permission denied"),
      findsOneWidget,
    );
    await chat.dispose();
  });

  testWidgets('fullscreen image viewer contains save control', (tester) async {
    final chat = FakeChatService();

    await tester.pumpWidget(
      MaterialApp(
        home: ChatFullscreenImagePage(
          imagePath: '/tmp/unused.png',
          eventId: 'evt_fs_img',
          roomId: '!r1',
          chat: chat,
          mediaSaver: FakeMediaSaver(),
          displayImage: false,
        ),
      ),
    );

    expect(find.byKey(const ValueKey('media-save-evt_fs_img')), findsOneWidget);
    await chat.dispose();
  });

  testWidgets('fullscreen video player contains save control', (tester) async {
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();
    final chat = FakeChatService();
    final controller = VideoPlayerController.file(File('/tmp/test.mp4'));

    await tester.pumpWidget(
      MaterialApp(
        home: ChatFullscreenVideoPage(
          eventId: 'evt_fs_vid',
          roomId: '!r1',
          chat: chat,
          videoPath: '/tmp/test.mp4',
          mediaSaver: FakeMediaSaver(),
          controller: controller,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('media-save-evt_fs_vid')), findsOneWidget);
    controller.dispose();
    await chat.dispose();
  });

  test('ChatMessage media helpers', () {
    final img = ChatMessage(
      eventId: 'e',
      body: '[photo.jpg]',
      senderId: '@a:b',
      tsMs: 0,
      isOwn: true,
      msgtype: 'm.image',
      filename: 'photo.jpg',
    );
    expect(img.isImage, isTrue);
    expect(img.mediaCaption, isNull);

    final withCap = ChatMessage(
      eventId: 'e2',
      body: 'sunset',
      senderId: '@a:b',
      tsMs: 0,
      isOwn: true,
      msgtype: 'm.image',
      filename: 'photo.jpg',
    );
    expect(withCap.mediaCaption, 'sunset');
  });
}
