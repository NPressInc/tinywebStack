import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app_session.dart';
import '../brand.dart';
import 'ics.dart';
import 'calendar_service.dart';
import 'event_editor_screen.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({
    super.key,
    required this.session,
    this.service,
  });

  final AppSession session;
  final CalendarService? service;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  CalendarService? _service;
  List<CalendarEventView> _events = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    if (widget.service == null) {
      _service?.dispose();
    }
    super.dispose();
  }

  CalendarService _openService() {
    if (widget.service != null) {
      return widget.service!;
    }
    _service ??= CalendarService(bundle: widget.session.enrollment!);
    return _service!;
  }

  Future<void> _refresh() async {
    final bundle = widget.session.enrollment;
    if (bundle == null) {
      return;
    }
    if (bundle.caldavCredentials == null) {
      setState(() {
        _loading = false;
        _error = 'Calendar not available on this device. Enroll again to refresh credentials.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final events = await _openService().loadUpcoming();
      setState(() {
        _events = events;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openCreate() async {
    final bundle = widget.session.enrollment;
    if (bundle == null) {
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (ctx) => EventEditorScreen(
          session: widget.session,
          service: _openService(),
        ),
      ),
    );
    if (saved == true) {
      await _refresh();
    }
  }

  Future<void> _openEvent(CalendarEventView view) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (ctx) => EventEditorScreen(
          session: widget.session,
          service: _openService(),
          existing: view,
        ),
      ),
    );
    if (saved == true) {
      await _refresh();
    }
  }

  Future<void> _respond(CalendarEventView view, bool accept) async {
    try {
      await _openService().respondToInvite(view, accept: accept);
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      floatingActionButton: widget.session.enrollment?.caldavCredentials != null
          ? FloatingActionButton(
              onPressed: _openCreate,
              child: const Icon(Icons.add),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _events.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Center(child: CircularProgressIndicator()),
        ],
      );
    }
    if (_error != null && _events.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      );
    }
    if (_events.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 80),
          Center(child: Text('No upcoming events')),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _events.length,
      itemBuilder: (context, index) {
        final view = _events[index];
        return _EventTile(
          view: view,
          onTap: () => _openEvent(view),
          onAccept: view.needsMyResponse ? () => _respond(view, true) : null,
          onDecline: view.needsMyResponse ? () => _respond(view, false) : null,
        );
      },
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.view,
    required this.onTap,
    this.onAccept,
    this.onDecline,
  });

  final CalendarEventView view;
  final VoidCallback onTap;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;

  @override
  Widget build(BuildContext context) {
    final ev = view.event;
    final title = ev.summary.isNotEmpty ? ev.summary : '(No title)';
    final when = _formatWhen(ev);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: TinyWebColors.text,
                          ),
                    ),
                  ),
                  if (view.needsMyResponse)
                    Chip(
                      label: const Text('Invite'),
                      backgroundColor: TinyWebColors.bgSoft,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(when, style: Theme.of(context).textTheme.bodyMedium),
              Text(
                view.calendar.displayName,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (ev.location.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(ev.location, style: Theme.of(context).textTheme.bodySmall),
              ],
              if (onAccept != null && onDecline != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(onPressed: onDecline, child: const Text('Decline')),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: onAccept, child: const Text('Accept')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatWhen(IcsEvent ev) {
    final start = ev.dtStart;
    if (start == null) {
      return 'Time TBD';
    }
    if (ev.allDay) {
      final end = ev.dtEnd;
      final s = _dateLabel(start);
      if (end != null && !_sameDay(start, end)) {
        return '$s – ${_dateLabel(end)}';
      }
      return s;
    }
    final local = start.toLocal();
    final end = ev.dtEnd?.toLocal();
    final startStr =
        '${_dateLabel(local)} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (end == null) {
      return startStr;
    }
    final endStr =
        '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
    if (_sameDay(local, end)) {
      return '$startStr – $endStr';
    }
    return '$startStr – ${_dateLabel(end)} $endStr';
  }

  String _dateLabel(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
