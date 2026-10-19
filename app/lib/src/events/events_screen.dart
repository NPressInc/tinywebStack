import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app_session.dart';
import '../brand.dart';
import 'event_create_screen.dart';
import 'event_detail_screen.dart';
import 'events_models.dart';
import 'events_service.dart';
import 'events_format.dart';

class EventsScreen extends StatefulWidget {
  const EventsScreen({
    super.key,
    required this.session,
    this.service,
  });

  final AppSession session;
  final EventsService? service;

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  EventsService? _service;
  List<MobilizonEventSummary> _events = [];
  bool _loading = true;
  String? _error;

  bool get _isParent => widget.session.profile?.role == 'parent';

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

  EventsService _openService() {
    if (widget.service != null) {
      return widget.service!;
    }
    _service ??= EventsService(bundle: widget.session.enrollment!);
    return _service!;
  }

  Future<void> _refresh() async {
    final bundle = widget.session.enrollment;
    if (bundle == null) {
      return;
    }
    if (bundle.mobilizonCredentials == null) {
      setState(() {
        _loading = false;
        _error =
            'Events not linked on this device. Enroll with your family password (not a one-time code).';
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
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (ctx) => EventCreateScreen(
          session: widget.session,
          service: _openService(),
        ),
      ),
    );
    if (saved == true) {
      await _refresh();
    }
  }

  Future<void> _openEvent(MobilizonEventSummary event) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => EventDetailScreen(
          session: widget.session,
          service: _openService(),
          initial: event,
        ),
      ),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final hasCreds =
        widget.session.enrollment?.mobilizonCredentials != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Events'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      floatingActionButton: _isParent && hasCreds
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
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
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
        final event = _events[index];
        return _EventTile(
          event: event,
          onTap: () => _openEvent(event),
        );
      },
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event, required this.onTap});

  final MobilizonEventSummary event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = event.title.isNotEmpty ? event.title : '(No title)';
    final when = formatMobilizonWhen(event.beginsOn, event.endsOn);
    final location = event.physicalAddress.label;
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
                  if (event.isJoined)
                    Chip(
                      label: const Text('Going'),
                      backgroundColor: TinyWebColors.bgSoft,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(when, style: Theme.of(context).textTheme.bodyMedium),
              if (event.isFederated)
                Text(
                  'From ${event.attributedTo.domain ?? event.organizer.domain ?? 'another home'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (location.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(location, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
