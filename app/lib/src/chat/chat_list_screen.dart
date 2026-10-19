import 'package:flutter/material.dart';

import '../api/family_api.dart';
import '../app_session.dart';
import '../brand.dart';
import '../enroll/secure_recovery_screen.dart';
import 'chat_service.dart';
import 'room_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({
    super.key,
    required this.session,
    required this.chat,
  });

  final AppSession session;
  final ChatService chat;

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  bool _recoverySkipped = false;

  @override
  void initState() {
    super.initState();
    widget.chat.roomsListenable.addListener(_onRoomsChanged);
    if (widget.chat.isConfigured) {
      widget.chat.refreshRooms();
    }
    _loadRecoveryFlag();
  }

  Future<void> _loadRecoveryFlag() async {
    final skipped =
        await widget.session.credentialStore.isMatrixRecoverySkipped();
    if (mounted) {
      setState(() => _recoverySkipped = skipped);
    }
  }

  @override
  void dispose() {
    widget.chat.roomsListenable.removeListener(_onRoomsChanged);
    super.dispose();
  }

  void _onRoomsChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    if (!widget.chat.isConfigured) {
      return Scaffold(
        appBar: AppBar(title: const Text('Chat')),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "Chat isn't set up for this device yet — ask a parent to re-send the setup code",
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final rooms = widget.chat.rooms;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'New chat',
            onPressed: _startNewChat,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_recoverySkipped)
            MaterialBanner(
              content: const Text(
                'Enter recovery key to read older messages on this device.',
              ),
              leading: const Icon(Icons.lock_outline),
              actions: [
                TextButton(
                  onPressed: () async {
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (ctx) =>
                            SecureRecoveryScreen(session: widget.session),
                      ),
                    );
                    await _loadRecoveryFlag();
                    if (widget.chat.isConfigured) {
                      await widget.chat.refreshRooms();
                    }
                  },
                  child: const Text('Enter key'),
                ),
              ],
            ),
          Expanded(
            child: RefreshIndicator(
        onRefresh: widget.chat.refreshRooms,
        child: rooms.isEmpty
            ? ListView(
                children: const [
                  SizedBox(height: 120),
                  Center(child: Text('No conversations yet')),
                ],
              )
            : ListView.builder(
                itemCount: rooms.length,
                itemBuilder: (context, index) {
                  final room = rooms[index];
                  return ListTile(
                    leading: room.encrypted
                        ? const Icon(Icons.lock, size: 20)
                        : null,
                    title: Text(room.title),
                    subtitle: Text(
                      room.lastMessage ?? 'No messages yet',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (room.lastTsMs != null)
                          Text(
                            _formatTime(room.lastTsMs!),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        if (room.unread > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: CircleAvatar(
                              radius: 10,
                              backgroundColor: TinyWebColors.blueDeep,
                              child: Text(
                                '${room.unread}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    onTap: () => _openRoom(room.roomId, room.title),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(int tsMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(tsMs);
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    return '${dt.month}/${dt.day}';
  }

  Future<void> _openRoom(String roomId, String title) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => RoomScreen(
          roomId: roomId,
          title: title,
          chat: widget.chat,
          profile: widget.session.profile!,
        ),
      ),
    );
  }

  Future<void> _startNewChat() async {
    final bundle = widget.session.enrollment!;
    final profile = widget.session.profile!;
    final isParent = profile.role == 'parent';

    String? targetMxid;

    if (isParent) {
      try {
        final members = await FamilyApiClient().fetchMembers(bundle);
        final others = members
            .where((m) => m.mxid.isNotEmpty && m.mxid != bundle.mxid)
            .toList();
        if (others.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No family members found')),
          );
          return;
        }
        if (!mounted) return;
        targetMxid = await showModalBottomSheet<String>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'New chat',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                ...others.map(
                  (m) => ListTile(
                    title: Text(m.displayName ?? m.username),
                    subtitle: Text(m.mxid),
                    onTap: () => Navigator.pop(ctx, m.mxid),
                  ),
                ),
              ],
            ),
          ),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load family members: $e')),
        );
        return;
      }
    } else {
      targetMxid = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final controller = TextEditingController();
          return AlertDialog(
            title: const Text('New chat'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: '@user:your.family.server',
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                child: const Text('Start'),
              ),
            ],
          );
        },
      );
    }

    if (targetMxid == null || targetMxid.isEmpty) {
      return;
    }

    try {
      final roomId = await widget.chat.createDirectChat(targetMxid);
      await widget.chat.refreshRooms();
      if (!mounted) return;
      final room = widget.chat.rooms.firstWhere(
        (r) => r.roomId == roomId,
        orElse: () => widget.chat.rooms.first,
      );
      await _openRoom(roomId, room.title);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start chat: $e')),
      );
    }
  }
}
