import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'chat_service.dart';
import 'media_save_button.dart';
import 'media_saver.dart';

/// Orientations used by the app outside immersive fullscreen media.
const List<DeviceOrientation> kChatDefaultOrientations = [
  DeviceOrientation.portraitUp,
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];

const List<DeviceOrientation> kFullscreenMediaOrientations = [
  DeviceOrientation.portraitUp,
  DeviceOrientation.portraitDown,
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];

class ChatFullscreenImagePage extends StatelessWidget {
  const ChatFullscreenImagePage({
    super.key,
    required this.imagePath,
    required this.eventId,
    required this.roomId,
    required this.chat,
    required this.mediaSaver,
    this.displayImage = true,
  });

  final String imagePath;
  final bool displayImage;
  final String eventId;
  final String roomId;
  final ChatService chat;
  final MediaSaver mediaSaver;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          MediaSaveButton(
            key: ValueKey('media-save-$eventId'),
            eventId: eventId,
            roomId: roomId,
            chat: chat,
            isVideo: false,
            mediaSaver: mediaSaver,
          ),
        ],
      ),
      body: Center(
        child: displayImage
            ? InteractiveViewer(
                child: Image.file(File(imagePath), fit: BoxFit.contain),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

class ChatFullscreenVideoPage extends StatefulWidget {
  const ChatFullscreenVideoPage({
    super.key,
    required this.eventId,
    required this.roomId,
    required this.chat,
    required this.videoPath,
    required this.mediaSaver,
    this.controller,
  });

  final String eventId;
  final String roomId;
  final ChatService chat;
  final String videoPath;
  final MediaSaver mediaSaver;

  /// When set (tests), skips [VideoPlayerController.file] initialization.
  final VideoPlayerController? controller;

  @override
  State<ChatFullscreenVideoPage> createState() => _ChatFullscreenVideoPageState();
}

class _ChatFullscreenVideoPageState extends State<ChatFullscreenVideoPage> {
  VideoPlayerController? _controller;
  bool _initializing = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(kFullscreenMediaOrientations);
    _initController();
  }

  Future<void> _initController() async {
    try {
      final controller = widget.controller ??
          VideoPlayerController.file(File(widget.videoPath));
      _controller = controller;
      if (!controller.value.isInitialized) {
        await controller.initialize();
      }
      controller.addListener(_onTick);
      if (!mounted) {
        return;
      }
      setState(() => _initializing = false);
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.toString();
        _initializing = false;
      });
    }
  }

  void _onTick() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(kChatDefaultOrientations);
    final controller = _controller;
    if (controller != null && widget.controller == null) {
      controller.removeListener(_onTick);
      controller.dispose();
    } else if (controller != null) {
      controller.removeListener(_onTick);
    }
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$m:$s';
    }
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          MediaSaveButton(
            key: ValueKey('media-save-${widget.eventId}'),
            eventId: widget.eventId,
            roomId: widget.roomId,
            chat: widget.chat,
            isVideo: true,
            mediaSaver: widget.mediaSaver,
          ),
        ],
      ),
      body: _initializing
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _error != null
              ? Center(
                  child: Text(
                    'Could not play video',
                    style: const TextStyle(color: Colors.white70),
                  ),
                )
              : _buildPlayer(),
    );
  }

  Widget _buildPlayer() {
    final controller = _controller!;
    final value = controller.value;
    final position = value.position;
    final duration = value.duration;
    final maxMs = duration.inMilliseconds.clamp(1, 1 << 31);

    return Column(
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () {
                      if (value.isPlaying) {
                        controller.pause();
                      } else {
                        controller.play();
                      }
                    },
                    icon: Icon(
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: position.inMilliseconds
                          .clamp(0, maxMs)
                          .toDouble(),
                      max: maxMs.toDouble(),
                      onChanged: (v) {
                        controller.seekTo(Duration(milliseconds: v.round()));
                      },
                      activeColor: Colors.white,
                      inactiveColor: Colors.white38,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(position),
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Text(
                      _formatDuration(duration),
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
