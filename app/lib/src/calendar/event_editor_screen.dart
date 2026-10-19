import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app_session.dart';
import 'caldav_client.dart';
import 'calendar_service.dart';

class EventEditorScreen extends StatefulWidget {
  const EventEditorScreen({
    super.key,
    required this.session,
    required this.service,
    this.existing,
  });

  final AppSession session;
  final CalendarService service;
  final CalendarEventView? existing;

  @override
  State<EventEditorScreen> createState() => _EventEditorScreenState();
}

class _EventEditorScreenState extends State<EventEditorScreen> {
  final _titleCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  bool _allDay = false;
  DateTime _start = DateTime.now().add(const Duration(hours: 1));
  DateTime _end = DateTime.now().add(const Duration(hours: 2));
  List<CalDavCalendar> _calendars = [];
  CalDavCalendar? _selectedCalendar;
  List<FamilyMember> _members = [];
  final Set<String> _invited = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  bool get _canEdit {
    final view = widget.existing;
    if (view == null) {
      return true;
    }
    return view.isOrganizer || view.event.organizerEmail == null;
  }

  bool get _canDelete {
    final view = widget.existing;
    if (view == null) {
      return false;
    }
    return view.isOrganizer;
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locationCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final cals = await widget.service.listCalendars();
      final members = await widget.service.fetchFamilyMembers();
      _calendars = cals;
      _members = members;
      final view = widget.existing;
      if (view != null) {
        _titleCtrl.text = view.event.summary;
        _locationCtrl.text = view.event.location;
        _notesCtrl.text = view.event.description;
        _allDay = view.event.allDay;
        _start = view.event.dtStart?.toLocal() ?? _start;
        _end = view.event.dtEnd?.toLocal() ?? _end;
        _selectedCalendar = view.calendar;
        for (final a in view.event.attendees) {
          final email = a.email.replaceFirst(RegExp(r'^mailto:', caseSensitive: false), '');
          final user = email.split('@').first;
          _invited.add(user);
        }
      } else {
        CalDavCalendar? familyCal;
        for (final c in cals) {
          if (c.calendarId == 'tws-family') {
            familyCal = c;
            break;
          }
        }
        _selectedCalendar = familyCal ?? (cals.isNotEmpty ? cals.first : null);
      }
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _pickDateTime({required bool isStart}) async {
    final initial = isStart ? _start : _end;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (date == null) {
      return;
    }
    if (_allDay) {
      setState(() {
        if (isStart) {
          _start = DateTime(date.year, date.month, date.day);
          if (!_end.isAfter(_start)) {
            _end = _start.add(const Duration(days: 1));
          }
        } else {
          _end = DateTime(date.year, date.month, date.day);
          if (!_end.isAfter(_start)) {
            _end = _start.add(const Duration(days: 1));
          }
        }
      });
      return;
    }
    if (!mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) {
      return;
    }
    final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isStart) {
        _start = dt;
        if (!_end.isAfter(_start)) {
          _end = _start.add(const Duration(hours: 1));
        }
      } else {
        _end = dt;
      }
    });
  }

  List<FamilyMember> _selectedAttendees() {
    return _members.where((m) => _invited.contains(m.username)).toList();
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Title is required')),
      );
      return;
    }
    final cal = _selectedCalendar;
    if (cal == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isEdit && widget.existing != null) {
        await widget.service.updateEvent(
          view: widget.existing!,
          title: _titleCtrl.text.trim(),
          start: _start,
          end: _end,
          allDay: _allDay,
          location: _locationCtrl.text.trim(),
          notes: _notesCtrl.text.trim(),
          attendees: _selectedAttendees(),
        );
      } else {
        await widget.service.createEvent(
          calendar: cal,
          title: _titleCtrl.text.trim(),
          start: _start,
          end: _end,
          allDay: _allDay,
          location: _locationCtrl.text.trim(),
          notes: _notesCtrl.text.trim(),
          attendees: _selectedAttendees(),
        );
      }
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _delete() async {
    final view = widget.existing;
    if (view == null) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete event?'),
        content: const Text('This removes the event from your calendar.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.service.deleteEvent(view);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Event' : 'New event'),
        actions: [
          if (_canDelete)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _saving ? null : _delete,
            ),
          TextButton(
            onPressed: !_canEdit || _saving ? null : _save,
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (!_canEdit)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'You can accept or decline this invite from the calendar list.',
                        ),
                      ),
                    TextField(
                      controller: _titleCtrl,
                      decoration: const InputDecoration(labelText: 'Title'),
                      enabled: _canEdit,
                    ),
                    const SizedBox(height: 12),
                    if (!_isEdit)
                      DropdownButtonFormField<CalDavCalendar>(
                        initialValue: _selectedCalendar,
                        decoration: const InputDecoration(labelText: 'Calendar'),
                        items: _calendars
                            .map(
                              (c) => DropdownMenuItem(
                                value: c,
                                child: Text(c.displayName),
                              ),
                            )
                            .toList(),
                        onChanged: _canEdit
                            ? (v) => setState(() => _selectedCalendar = v)
                            : null,
                      ),
                    SwitchListTile(
                      title: const Text('All day'),
                      value: _allDay,
                      onChanged: _canEdit
                          ? (v) => setState(() => _allDay = v)
                          : null,
                    ),
                    ListTile(
                      title: const Text('Starts'),
                      subtitle: Text(_formatDt(_start, _allDay)),
                      onTap: _canEdit ? () => _pickDateTime(isStart: true) : null,
                    ),
                    ListTile(
                      title: const Text('Ends'),
                      subtitle: Text(_formatDt(_end, _allDay)),
                      onTap: _canEdit ? () => _pickDateTime(isStart: false) : null,
                    ),
                    TextField(
                      controller: _locationCtrl,
                      decoration: const InputDecoration(labelText: 'Location'),
                      enabled: _canEdit,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _notesCtrl,
                      decoration: const InputDecoration(labelText: 'Notes'),
                      maxLines: 3,
                      enabled: _canEdit,
                    ),
                    const SizedBox(height: 16),
                    Text('Invite family', style: Theme.of(context).textTheme.titleSmall),
                    ..._members
                        .where((m) => m.username != widget.session.enrollment?.username)
                        .map(
                          (m) => CheckboxListTile(
                            title: Text(m.displayName ?? m.username),
                            subtitle: Text(m.role),
                            value: _invited.contains(m.username),
                            onChanged: !_canEdit
                                ? null
                                : (v) {
                                    setState(() {
                                      if (v == true) {
                                        _invited.add(m.username);
                                      } else {
                                        _invited.remove(m.username);
                                      }
                                    });
                                  },
                          ),
                        ),
                  ],
                ),
    );
  }

  String _formatDt(DateTime dt, bool allDay) {
    if (allDay) {
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    }
    return dt.toLocal().toString().substring(0, 16);
  }
}
