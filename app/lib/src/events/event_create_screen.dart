import 'package:flutter/material.dart';

import '../app_session.dart';
import 'events_service.dart';

class EventCreateScreen extends StatefulWidget {
  const EventCreateScreen({
    super.key,
    required this.session,
    required this.service,
  });

  final AppSession session;
  final EventsService service;

  @override
  State<EventCreateScreen> createState() => _EventCreateScreenState();
}

class _EventCreateScreenState extends State<EventCreateScreen> {
  final _titleController = TextEditingController();
  final _locationController = TextEditingController();
  final _descriptionController = TextEditingController();
  DateTime _start = DateTime.now().add(const Duration(days: 1));
  DateTime _end = DateTime.now().add(const Duration(days: 1, hours: 2));
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_start),
    );
    if (time == null) {
      return;
    }
    setState(() {
      _start = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      if (!_end.isAfter(_start)) {
        _end = _start.add(const Duration(hours: 2));
      }
    });
  }

  Future<void> _pickEnd() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _end,
      firstDate: _start,
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_end),
    );
    if (time == null) {
      return;
    }
    setState(() {
      _end = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Title is required');
      return;
    }
    if (!_end.isAfter(_start)) {
      setState(() => _error = 'End must be after start');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.createEvent(
        title: title,
        beginsOn: _start,
        endsOn: _end,
        description: _descriptionController.text.trim(),
        location: _locationController.text.trim(),
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New event'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          ListTile(
            title: const Text('Starts'),
            subtitle: Text(_start.toLocal().toString().substring(0, 16)),
            trailing: const Icon(Icons.calendar_today),
            onTap: _saving ? null : _pickStart,
          ),
          ListTile(
            title: const Text('Ends'),
            subtitle: Text(_end.toLocal().toString().substring(0, 16)),
            trailing: const Icon(Icons.calendar_today),
            onTap: _saving ? null : _pickEnd,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _locationController,
            decoration: const InputDecoration(
              labelText: 'Location (optional)',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              border: OutlineInputBorder(),
            ),
            minLines: 3,
            maxLines: 6,
          ),
          const SizedBox(height: 8),
          const Text(
            'New events are Public so trusted family boxes can see federated copies.',
            style: TextStyle(fontSize: 13),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
