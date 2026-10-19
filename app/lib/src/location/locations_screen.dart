import 'package:flutter/material.dart';

import '../api/family_api.dart';
import '../api/models.dart';
import '../app_session.dart';
import '../brand.dart';

class LocationsScreen extends StatefulWidget {
  const LocationsScreen({
    super.key,
    required this.session,
    this.api,
  });

  final AppSession session;
  final FamilyApiClient? api;

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen> {
  late final FamilyApiClient _api = widget.api ?? FamilyApiClient();
  List<KidLocationSnapshot> _kids = [];
  String? _status;
  bool _loading = true;
  String? _error;
  String? _selectedKid;
  KidTrackResponse? _track;
  bool _trackLoading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    if (widget.api == null) {
      _api.close();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    final bundle = widget.session.enrollment;
    if (bundle == null) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await _api.fetchLocations(bundle);
      setState(() {
        _kids = response.kids;
        _status = response.status;
        _loading = false;
        if (_selectedKid == null && _kids.isNotEmpty) {
          _selectedKid = _kids.first.username;
        }
      });
      if (_selectedKid != null) {
        await _loadTrack(_selectedKid!);
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadTrack(String username) async {
    final bundle = widget.session.enrollment;
    if (bundle == null) {
      return;
    }
    setState(() {
      _selectedKid = username;
      _trackLoading = true;
    });
    try {
      final track = await _api.fetchKidTrack(bundle, username, hours: 24);
      setState(() {
        _track = track;
        _trackLoading = false;
      });
    } catch (e) {
      setState(() {
        _trackLoading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Locations'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _loading
            ? ListView(
                children: const [
                  SizedBox(height: 120),
                  Center(child: CircularProgressIndicator()),
                ],
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_status == 'unavailable')
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text('Location service is temporarily unavailable.'),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!, style: const TextStyle(color: Colors.red)),
                    ),
                  // TODO: family map with self-hosted tiles (no third-party OSM in this PR).
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Map view is not included yet — coordinates and track points only.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  ..._kids.map(_kidCard),
                  if (_selectedKid != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      '24 h track — $_selectedKid',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (_trackLoading)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_track != null)
                      ..._track!.points.map(_trackRow),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _kidCard(KidLocationSnapshot kid) {
    final selected = kid.username == _selectedKid;
    final lastSeen = kid.ageSeconds != null ? '${kid.ageSeconds}s ago' : 'no data';
    return Card(
      color: selected ? TinyWebColors.bgSoft : null,
      child: ListTile(
        title: Text(kid.displayName.isNotEmpty ? kid.displayName : kid.username),
        subtitle: Text(
          [
            'Last seen: $lastSeen',
            if (kid.lat != null && kid.lon != null)
              '${kid.lat!.toStringAsFixed(5)}, ${kid.lon!.toStringAsFixed(5)}',
            if (kid.acc != null) '±${kid.acc!.round()} m',
            if (kid.batt != null) 'Battery ${kid.batt}%',
          ].join(' · '),
        ),
        onTap: () => _loadTrack(kid.username),
        trailing: selected ? const Icon(Icons.check) : null,
      ),
    );
  }

  Widget _trackRow(TrackPoint point) {
    final when = point.tst != null
        ? DateTime.fromMillisecondsSinceEpoch(point.tst! * 1000).toLocal()
        : null;
    return ListTile(
      dense: true,
      title: Text(
        point.lat != null && point.lon != null
            ? '${point.lat!.toStringAsFixed(5)}, ${point.lon!.toStringAsFixed(5)}'
            : '—',
      ),
      subtitle: Text(
        [
          if (when != null) when.toString(),
          if (point.acc != null) '±${point.acc!.round()} m',
          if (point.batt != null) '${point.batt}%',
        ].join(' · '),
      ),
    );
  }
}
