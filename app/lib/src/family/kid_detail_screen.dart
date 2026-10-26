import 'package:flutter/material.dart';

import '../api/family_api.dart';
import '../api/models.dart';
import '../app_session.dart';
class KidDetailScreen extends StatefulWidget {
  const KidDetailScreen({
    super.key,
    required this.session,
    required this.kid,
    this.api,
  });

  final AppSession session;
  final FamilyMember kid;
  final FamilyApiClient? api;

  @override
  State<KidDetailScreen> createState() => _KidDetailScreenState();
}

class _KidDetailScreenState extends State<KidDetailScreen> {
  late final FamilyApiClient _api = widget.api ?? FamilyApiClient();
  KidPermissions? _permissions;
  List<FamilyMember> _householdMembers = [];
  List<String> _trustedDomains = [];
  bool _loading = true;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (widget.api == null) {
      _api.close();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final bundle = widget.session.enrollment;
    if (bundle == null) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _api.fetchKidPermissions(bundle, widget.kid.username),
        _api.fetchMembers(bundle),
        _api.fetchFederationPeers(bundle),
      ]);
      final perms = results[0] as KidPermissions;
      final members = results[1] as List<FamilyMember>;
      final federation = results[2] as FederationPeersResponse;
      setState(() {
        _permissions = perms;
        _householdMembers = members;
        _trustedDomains = federation.trustedDomains;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _mutate(
    KidPermissions optimistic,
    Map<String, dynamic> body,
  ) async {
    final bundle = widget.session.enrollment;
    if (bundle == null || _permissions == null) {
      return;
    }
    final previous = _permissions!;
    setState(() {
      _permissions = optimistic;
      _saving = true;
    });
    try {
      final updated =
          await _api.updateKidPermissions(bundle, widget.kid.username, body);
      setState(() {
        _permissions = updated;
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _permissions = previous;
        _saving = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e')),
        );
      }
    }
  }

  void _toggleEvents(bool value) {
    final current = _permissions!;
    _mutate(
      current.copyWith(eventsEnabled: value),
      {'events_enabled': value},
    );
  }

  void _toggleQuietHours(bool enabled) {
    final current = _permissions!;
    if (!enabled) {
      _mutate(
        current.copyWith(clearQuietHours: true),
        {'revoke': ['quiet_hours']},
      );
      return;
    }
    final qh = current.quietHours ??
        QuietHoursConfig(
          start: '21:00',
          end: '07:00',
          timezone: 'America/Denver',
        );
    _mutate(
      current.copyWith(quietHours: qh),
      {'quiet_hours': qh.toJson()},
    );
  }

  void _updateQuietHours(QuietHoursConfig qh) {
    final current = _permissions!;
    _mutate(
      current.copyWith(quietHours: qh),
      {'quiet_hours': qh.toJson()},
    );
  }

  static const _commonTimezones = [
    'America/Denver',
    'America/Los_Angeles',
    'America/Phoenix',
    'America/Chicago',
    'America/New_York',
    'America/Anchorage',
    'Pacific/Honolulu',
    'Europe/London',
    'Europe/Dublin',
    'Europe/Paris',
    'UTC',
  ];

  TimeOfDay _parseHm(String value) {
    final parts = value.split(':');
    final h = int.tryParse(parts.first) ?? 0;
    final m = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
    return TimeOfDay(hour: h.clamp(0, 23), minute: m.clamp(0, 59));
  }

  String _formatHm(TimeOfDay time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }

  String _friendlyTimeLabel(String hhmm) {
    final time = _parseHm(hhmm);
    final hour12 = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final period = time.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour12:${time.minute.toString().padLeft(2, '0')} '
        '$period (${_formatHm(time)})';
  }

  Future<void> _pickQuietHoursTime({
    required QuietHoursConfig qh,
    required bool isStart,
  }) async {
    if (_saving) {
      return;
    }
    final initial = _parseHm(isStart ? qh.start : qh.end);
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
    );
    if (picked == null || !mounted) {
      return;
    }
    final formatted = _formatHm(picked);
    _updateQuietHours(
      isStart ? qh.copyWith(start: formatted) : qh.copyWith(end: formatted),
    );
  }

  Future<void> _promptManualQuietHoursTime({
    required QuietHoursConfig qh,
    required bool isStart,
  }) async {
    if (_saving) {
      return;
    }
    final controller = TextEditingController(
      text: isStart ? qh.start : qh.end,
    );
    final entered = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isStart ? 'Start time' : 'End time'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'HH:MM'),
          autocorrect: false,
          keyboardType: TextInputType.datetime,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (entered == null || entered.isEmpty) {
      return;
    }
    _updateQuietHours(
      isStart ? qh.copyWith(start: entered) : qh.copyWith(end: entered),
    );
  }

  Future<void> _showTimezoneSheet(QuietHoursConfig qh) async {
    if (_saving) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Timezone',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              ..._commonTimezones.map(
                (tz) => ListTile(
                  title: Text(tz),
                  trailing: qh.timezone == tz ? const Icon(Icons.check) : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    _updateQuietHours(qh.copyWith(timezone: tz));
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Custom timezone…'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _promptCustomTimezone(qh);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _promptCustomTimezone(QuietHoursConfig qh) async {
    final controller = TextEditingController(text: qh.timezone);
    final entered = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Timezone'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'America/Denver'),
          autocorrect: false,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (entered == null || entered.isEmpty) {
      return;
    }
    _updateQuietHours(qh.copyWith(timezone: entered));
  }

  void _setAllowlistMxids(List<String> mxids) {
    final current = _permissions!;
    _mutate(
      current.copyWith(allowlistMxids: mxids),
      {'allowlist_mxids': mxids},
    );
  }

  void _setAllowlistDomains(List<String> domains) {
    final current = _permissions!;
    _mutate(
      current.copyWith(allowlistDomains: domains),
      {'allowlist_domains': domains},
    );
  }

  Future<void> _showAddContactSheet() async {
    final current = _permissions!;
    final suggestions = _householdMembers
        .where((m) => m.mxid.isNotEmpty && m.username != widget.kid.username)
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Add chat partner',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              if (suggestions.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No other household members with Matrix IDs.'),
                )
              else
                ...suggestions.map((m) {
                  final label = m.displayName?.isNotEmpty == true
                      ? m.displayName!
                      : m.username;
                  final already =
                      current.allowlistMxids.contains(m.mxid);
                  return ListTile(
                    title: Text(label),
                    subtitle: Text(m.mxid),
                    enabled: !already,
                    trailing: already ? const Icon(Icons.check) : null,
                    onTap: already
                        ? null
                        : () {
                            Navigator.pop(ctx);
                            _setAllowlistMxids([
                              ...current.allowlistMxids,
                              m.mxid,
                            ]);
                          },
                  );
                }),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Enter Matrix ID manually'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _promptManualMxid();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _promptManualMxid() async {
    final controller = TextEditingController();
    final added = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Matrix ID'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '@friend:other.family',
          ),
          autocorrect: false,
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
      ),
    );
    if (added == null || added.isEmpty) {
      return;
    }
    final mxid = added.startsWith('@') ? added : '@$added';
    final current = _permissions!;
    if (current.allowlistMxids.contains(mxid)) {
      return;
    }
    _setAllowlistMxids([...current.allowlistMxids, mxid]);
  }

  Future<void> _showAddDomainSheet() async {
    final current = _permissions!;
    final domains = _trustedDomains
        .where((d) => d.isNotEmpty)
        .where((d) => !current.allowlistDomains.contains(d))
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Trusted other homes',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              if (domains.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No linked families yet. Add a domain manually or link households on the dashboard.',
                  ),
                )
              else
                ...domains.map(
                  (d) => ListTile(
                    title: Text(d),
                    onTap: () {
                      Navigator.pop(ctx);
                      _setAllowlistDomains([...current.allowlistDomains, d]);
                    },
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Enter domain manually'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _promptManualDomain();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _promptManualDomain() async {
    final controller = TextEditingController();
    final added = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Trusted domain'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'other.family'),
          autocorrect: false,
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
      ),
    );
    if (added == null || added.isEmpty) {
      return;
    }
    final domain = added.toLowerCase();
    final current = _permissions!;
    if (current.allowlistDomains.contains(domain)) {
      return;
    }
    _setAllowlistDomains([...current.allowlistDomains, domain]);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.kid.displayName?.isNotEmpty == true
        ? widget.kid.displayName!
        : widget.kid.username;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    final perms = _permissions!;
    final qh = perms.quietHours ??
        QuietHoursConfig(
          start: '21:00',
          end: '07:00',
          timezone: 'America/Denver',
        );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Chat partners',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final mxid in perms.allowlistMxids)
              InputChip(
                label: Text(mxid, style: const TextStyle(fontSize: 12)),
                onDeleted: () {
                  _setAllowlistMxids(
                    perms.allowlistMxids.where((m) => m != mxid).toList(),
                  );
                },
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
              onPressed: _showAddContactSheet,
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          'Trusted other homes',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Allow messaging anyone on these Matrix homeservers.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final domain in perms.allowlistDomains)
              InputChip(
                label: Text(domain),
                onDeleted: () {
                  _setAllowlistDomains(
                    perms.allowlistDomains.where((d) => d != domain).toList(),
                  );
                },
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
              onPressed: _showAddDomainSheet,
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          'Quiet hours',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        SwitchListTile(
          value: perms.quietHoursEnabled,
          onChanged: _saving ? null : _toggleQuietHours,
          title: const Text('Pause messages overnight'),
          subtitle: const Text('Server blocks sends during this window'),
        ),
        if (perms.quietHoursEnabled) ...[
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: InkWell(
              key: const Key('quiet-hours-start'),
              onTap: _saving
                  ? null
                  : () => _pickQuietHoursTime(qh: qh, isStart: true),
              child: ListTile(
                title: const Text('Start'),
                subtitle: Text(_friendlyTimeLabel(qh.start)),
                trailing: IconButton(
                  key: const Key('quiet-hours-start-manual'),
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _saving
                      ? null
                      : () => _promptManualQuietHoursTime(
                            qh: qh,
                            isStart: true,
                          ),
                ),
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: InkWell(
              key: const Key('quiet-hours-end'),
              onTap: _saving
                  ? null
                  : () => _pickQuietHoursTime(qh: qh, isStart: false),
              child: ListTile(
                title: const Text('End'),
                subtitle: Text(_friendlyTimeLabel(qh.end)),
                trailing: IconButton(
                  key: const Key('quiet-hours-end-manual'),
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _saving
                      ? null
                      : () => _promptManualQuietHoursTime(
                            qh: qh,
                            isStart: false,
                          ),
                ),
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: InkWell(
              key: const Key('quiet-hours-timezone'),
              onTap: _saving ? null : () => _showTimezoneSheet(qh),
              child: ListTile(
                title: const Text('Timezone'),
                subtitle: Text(qh.timezone),
                trailing: const Icon(Icons.chevron_right),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'Events',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        SwitchListTile(
          value: perms.eventsEnabled,
          onChanged: _saving ? null : _toggleEvents,
          title: const Text('Allow Events app'),
          subtitle: const Text('Mobilizon RSVPs for this child'),
        ),
      ],
    );
  }
}
