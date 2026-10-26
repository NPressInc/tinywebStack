import 'package:flutter/material.dart';

import '../api/family_api.dart';
import '../api/models.dart';
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
    this.apiClient,
  });

  final AppSession session;
  final ChatService chat;
  final FamilyApiClient? apiClient;

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  bool _recoverySkipped = false;

  FamilyApiClient get _api => widget.apiClient ?? FamilyApiClient();

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

  Future<String?> _showManualMxidDialog() {
    return showDialog<String>(
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

  Future<String?> _showAddExternalMxidDialog() {
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Add Matrix ID'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: '@user:other.family',
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
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
  }

  String _normalizeMxid(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    return trimmed.startsWith('@') ? trimmed : '@$trimmed';
  }

  Future<void> _finishNewChat({
    required Future<String> Function() createRoom,
  }) async {
    try {
      final roomId = await createRoom();
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

  Future<void> _startNewChatParent(EnrollmentBundle bundle) async {
    try {
      final members = await _api.fetchMembers(bundle);
      final others = members
          .where((m) => m.mxid.isNotEmpty && m.mxid != bundle.mxid)
          .toList();
      if (!mounted) return;
      final result = await showModalBottomSheet<_ParentNewChatResult>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) {
          final selected = <String>{};
          final externalMxids = <String>[];
          final groupNameController = TextEditingController();
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: StatefulBuilder(
                builder: (context, setSheetState) {
                  final selectedMxids = [
                    ...others
                        .where((m) => selected.contains(m.mxid))
                        .map((m) => m.mxid),
                    ...externalMxids.where((id) => selected.contains(id)),
                  ];
                  final groupName = groupNameController.text.trim();
                  final createGroup = selectedMxids.length >= 2 ||
                      (groupName.isNotEmpty && selectedMxids.isNotEmpty);
                  final canStart = selectedMxids.isNotEmpty;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'New chat',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: TextField(
                          key: const Key('group_name_field'),
                          controller: groupNameController,
                          decoration: const InputDecoration(
                            labelText: 'Group name (optional)',
                            hintText: 'Family',
                          ),
                          onChanged: (_) => setSheetState(() {}),
                        ),
                      ),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            ...others.map(
                              (m) => CheckboxListTile(
                                value: selected.contains(m.mxid),
                                onChanged: (checked) {
                                  setSheetState(() {
                                    if (checked == true) {
                                      selected.add(m.mxid);
                                    } else {
                                      selected.remove(m.mxid);
                                    }
                                  });
                                },
                                title: Text(m.displayLabel),
                                subtitle: Text(m.mxid),
                              ),
                            ),
                            ...externalMxids.map(
                              (mxid) => CheckboxListTile(
                                value: selected.contains(mxid),
                                onChanged: (checked) {
                                  setSheetState(() {
                                    if (checked == true) {
                                      selected.add(mxid);
                                    } else {
                                      selected.remove(mxid);
                                    }
                                  });
                                },
                                title: Text(mxid),
                              ),
                            ),
                            ListTile(
                              key: const Key('parent-add-external-mxid'),
                              leading: const Icon(Icons.alternate_email),
                              title: const Text(
                                'Add Matrix ID (@user:domain)...',
                              ),
                              onTap: () async {
                                final raw = await _showAddExternalMxidDialog();
                                if (raw == null || raw.isEmpty) {
                                  return;
                                }
                                final mxid = _normalizeMxid(raw);
                                if (mxid.isEmpty) {
                                  return;
                                }
                                setSheetState(() {
                                  final inOthers =
                                      others.any((m) => m.mxid == mxid);
                                  if (!inOthers &&
                                      !externalMxids.contains(mxid)) {
                                    externalMxids.add(mxid);
                                  }
                                  selected.add(mxid);
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton(
                          key: const Key('start_chat_button'),
                          onPressed: canStart
                              ? () {
                                  Navigator.pop(
                                    ctx,
                                    _ParentNewChatResult(
                                      selectedMxids: selectedMxids,
                                      groupName: groupName,
                                      createGroup: createGroup,
                                    ),
                                  );
                                }
                              : null,
                          child: Text(
                            createGroup ? 'Create Group' : 'Start Chat',
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      );
      if (result == null || result.selectedMxids.isEmpty) {
        return;
      }
      await _finishNewChat(
        createRoom: () {
          if (result.createGroup) {
            return widget.chat.createGroupChat(
              result.groupName,
              result.selectedMxids,
            );
          }
          return widget.chat.createDirectChat(result.selectedMxids.first);
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load family members: $e')),
      );
    }
  }

  Future<void> _startNewChatKid(
    EnrollmentBundle bundle,
    AppMeProfile profile,
  ) async {
    List<ChatContact> contacts = [];
    try {
      contacts = await _api.fetchChatContacts(bundle);
    } catch (_) {}
    if (contacts.isEmpty) {
      contacts = profile.chatContacts;
    }

    String? targetMxid;

    if (contacts.isNotEmpty) {
      if (!mounted) return;
      const manualPicker = '__manual_mxid__';
      final picked = await showModalBottomSheet<String>(
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
              ...contacts.map(
                (c) => ListTile(
                  title: Text(c.displayLabel),
                  subtitle: Text(c.mxid),
                  onTap: () => Navigator.pop(ctx, c.mxid),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.alternate_email),
                title: const Text('Type Matrix ID...'),
                onTap: () => Navigator.pop(ctx, manualPicker),
              ),
            ],
          ),
        ),
      );
      if (picked == null) {
        return;
      }
      if (picked == manualPicker) {
        targetMxid = await _showManualMxidDialog();
      } else {
        targetMxid = picked;
      }
    } else {
      targetMxid = await _showManualMxidDialog();
    }

    if (targetMxid == null || targetMxid.isEmpty) {
      return;
    }

    await _finishNewChat(
      createRoom: () => widget.chat.createDirectChat(targetMxid!),
    );
  }

  Future<void> _startNewChat() async {
    final bundle = widget.session.enrollment!;
    final profile = widget.session.profile!;
    if (profile.role == 'parent') {
      await _startNewChatParent(bundle);
    } else {
      await _startNewChatKid(bundle, profile);
    }
  }
}

class _ParentNewChatResult {
  _ParentNewChatResult({
    required this.selectedMxids,
    required this.groupName,
    required this.createGroup,
  });

  final List<String> selectedMxids;
  final String groupName;
  final bool createGroup;
}
