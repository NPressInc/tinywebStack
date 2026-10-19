import 'package:flutter/material.dart';

import '../app_session.dart';
import '../brand.dart';
import 'events_format.dart';
import 'events_models.dart';
import 'events_service.dart';

class EventDetailScreen extends StatefulWidget {
  const EventDetailScreen({
    super.key,
    required this.session,
    required this.service,
    required this.initial,
  });

  final AppSession session;
  final EventsService service;
  final MobilizonEventSummary initial;

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  late MobilizonEventSummary _event;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _event = widget.initial;
    _reloadDetail();
  }

  Future<void> _reloadDetail() async {
    try {
      final fresh = await widget.service.loadEventByUuid(_event.uuid);
      if (mounted) {
        setState(() => _event = fresh);
      }
    } catch (_) {
      // Keep list snapshot if detail fetch fails.
    }
  }

  Future<void> _toggleRsvp() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = _event.isJoined
          ? await widget.service.leave(_event)
          : await widget.service.join(_event);
      setState(() {
        _event = updated;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final location = _event.physicalAddress.label;
    final organizer = _event.organizer.displayLabel;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Event'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _event.title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: TinyWebColors.text,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            formatMobilizonWhen(_event.beginsOn, _event.endsOn),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (location.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.place_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(location)),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text('Organizer: $organizer'),
          if (_event.visibility != null && _event.visibility!.isNotEmpty)
            Text('Visibility: ${_event.visibility}'),
          if (_event.goingCount != null)
            Text('${_event.goingCount} going'),
          if (_event.description != null &&
              _event.description!.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _event.description!.trim(),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _toggleRsvp,
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_event.isJoined ? 'Leave event' : 'Join event'),
          ),
        ],
      ),
    );
  }

}
