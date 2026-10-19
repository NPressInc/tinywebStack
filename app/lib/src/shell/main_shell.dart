import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app_session.dart';
import '../chat/chat_list_screen.dart';
import '../chat/chat_service.dart';
import '../home/home_screen.dart';
import '../calendar/calendar_screen.dart';
import '../events/events_screen.dart';
import '../family/kid_controls_screen.dart';
import '../location/locations_screen.dart';

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
    widget.session.locationService.addListener(_onLocationChanged);
    if (widget.chatService != null) {
      _chat = widget.chatService!;
    } else {
      _ownsChat = true;
      final bundle = widget.session.enrollment;
      if (bundle != null && bundle.matrixEnrollment.isOk) {
        _chat = RustChatService(
          bundle: bundle,
          credentialStore: widget.session.credentialStore,
        );
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
    widget.session.locationService.removeListener(_onLocationChanged);
    if (_ownsChat) {
      _chat.dispose();
    }
    super.dispose();
  }

  void _onLocationChanged() {
    if (mounted) {
      setState(() {});
    }
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

  bool get _isParent => widget.session.profile?.role == 'parent';

  bool get _showEventsTab {
    final profile = widget.session.profile;
    if (profile == null) {
      return false;
    }
    return _isParent || profile.eventsEnabled;
  }

  int _chatTabIndex() {
    if (_isParent) {
      return _showEventsTab ? 5 : 4;
    }
    return _showEventsTab ? 3 : 2;
  }

  int _calendarTabIndex() => 1;

  int _eventsTabIndex() => 2;

  int _familyTabIndex() => _showEventsTab ? 4 : 3;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomeScreen(
        session: widget.session,
        onOpenChat: () => _selectTab(_chatTabIndex()),
        onOpenCalendar: () => _selectTab(_calendarTabIndex()),
        onOpenEvents:
            _showEventsTab ? () => _selectTab(_eventsTabIndex()) : null,
        onOpenFamily:
            _isParent ? () => _selectTab(_familyTabIndex()) : null,
      ),
      CalendarScreen(session: widget.session),
      if (_showEventsTab) EventsScreen(session: widget.session),
      if (_isParent) LocationsScreen(session: widget.session),
      if (_isParent) KidControlsScreen(session: widget.session),
      ChatListScreen(session: widget.session, chat: _chat),
    ];

    final destinations = <NavigationDestination>[
      const NavigationDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home),
        label: 'Home',
      ),
      const NavigationDestination(
        icon: Icon(Icons.calendar_month_outlined),
        selectedIcon: Icon(Icons.calendar_month),
        label: 'Calendar',
      ),
      if (_showEventsTab)
        const NavigationDestination(
          icon: Icon(Icons.event_outlined),
          selectedIcon: Icon(Icons.event),
          label: 'Events',
        ),
      if (_isParent)
        const NavigationDestination(
          icon: Icon(Icons.location_on_outlined),
          selectedIcon: Icon(Icons.location_on),
          label: 'Locations',
        ),
      if (_isParent)
        const NavigationDestination(
          icon: Icon(Icons.family_restroom_outlined),
          selectedIcon: Icon(Icons.family_restroom),
          label: 'Family',
        ),
      const NavigationDestination(
        icon: Icon(Icons.chat_bubble_outline),
        selectedIcon: Icon(Icons.chat_bubble),
        label: 'Chat',
      ),
    ];

    return Scaffold(
      body: IndexedStack(index: _tabIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: _selectTab,
        destinations: destinations,
      ),
    );
  }
}
