import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app_session.dart';
import '../chat/chat_list_screen.dart';
import '../chat/chat_service.dart';
import '../home/home_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.session,
    this.chatService,
  });

  final AppSession session;
  final ChatService? chatService;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _tabIndex = 0;
  late ChatService _chat;
  bool _ownsChat = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.chatService != null) {
      _chat = widget.chatService!;
    } else {
      _ownsChat = true;
      final bundle = widget.session.enrollment;
      if (bundle != null && bundle.matrixEnrollment.isOk) {
        _chat = RustChatService(bundle: bundle);
        _bootstrapRustChat();
      } else {
        _chat = UnconfiguredChatService();
      }
    }
  }

  Future<void> _bootstrapRustChat() async {
    final rust = _chat as RustChatService;
    try {
      await rust.start();
    } catch (_) {
      // Keep UI usable; chat list shows errors on refresh.
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsChat) {
      _chat.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_chat.isConfigured) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _chat.startSync();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _chat.stopSync();
    }
  }

  void _selectTab(int index) {
    setState(() => _tabIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(
        session: widget.session,
        onOpenChat: () => _selectTab(1),
      ),
      ChatListScreen(session: widget.session, chat: _chat),
    ];

    return Scaffold(
      body: IndexedStack(index: _tabIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: _selectTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
        ],
      ),
    );
  }
}
