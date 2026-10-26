import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../api/family_api.dart';
import '../api/models.dart';
import '../api/tls_http_client.dart';
import '../app_session.dart';
import '../brand.dart';
import 'family_map_view.dart';

enum _LocationsViewMode { map, list }

String formatLocationAge(int? ageSeconds) {
  if (ageSeconds == null) {
    return 'no data';
  }
  final seconds = ageSeconds < 0 ? 0 : ageSeconds;
  if (seconds < 60) {
    return '${seconds}s ago';
  }
  if (seconds < 3600) {
    return '${seconds ~/ 60}m ago';
  }
  if (seconds < 86400) {
    return '${seconds ~/ 3600}h ago';
  }
  return '${seconds ~/ 86400}d ago';
}

String _formatTrackTimestamp(DateTime when) {
  final y = when.year;
  final m = when.month.toString().padLeft(2, '0');
  final d = when.day.toString().padLeft(2, '0');
  final h = when.hour.toString().padLeft(2, '0');
  final min = when.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $h:$min';
}

class LocationsScreen extends StatefulWidget {
  const LocationsScreen({
    super.key,
    required this.session,
    this.api,
    this.httpClient,
  });

  final AppSession session;
  final FamilyApiClient? api;
  final http.Client? httpClient;

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen> {
  late final FamilyApiClient _api = widget.api ?? FamilyApiClient();
  late final http.Client _mapHttpClient =
      widget.httpClient ?? defaultTlsHttpClient();
  List<KidLocationSnapshot> _kids = [];
  String? _status;
  bool _loading = true;
  String? _error;
  String? _selectedKid;
  KidTrackResponse? _track;
  bool _trackLoading = false;
  FamilyMapConfig? _mapConfig;
  _LocationsViewMode _viewMode = _LocationsViewMode.map;

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
    if (widget.httpClient != null) {
      _mapHttpClient.close();
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
      final mapFuture = _api.fetchMapConfig(bundle);
      final locationsFuture = _api.fetchLocations(bundle);
      final mapConfig = await mapFuture;
      final response = await locationsFuture;
      setState(() {
        _mapConfig = mapConfig;
        _kids = response.kids;
        _status = response.status;
        _loading = false;
        if (!mapConfig.available) {
          _viewMode = _LocationsViewMode.list;
        }
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

  Future<void> _openInMaps(KidLocationSnapshot kid) async {
    final label =
        kid.displayName.isNotEmpty ? kid.displayName : kid.username;
    final Uri uri;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      uri = Uri.parse(
        'https://maps.apple.com/?ll=${kid.lat},${kid.lon}&q=${Uri.encodeComponent(label)}',
      );
    } else {
      uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=${kid.lat},${kid.lon}',
      );
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
    final mapReady = _mapConfig?.available == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Locations'),
        actions: [
          if (mapReady)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SegmentedButton<_LocationsViewMode>(
                segments: const [
                  ButtonSegment(
                    value: _LocationsViewMode.map,
                    label: Text('Map'),
                    icon: Icon(Icons.map_outlined),
                  ),
                  ButtonSegment(
                    value: _LocationsViewMode.list,
                    label: Text('List'),
                    icon: Icon(Icons.list),
                  ),
                ],
                selected: {_viewMode},
                onSelectionChanged: (set) {
                  setState(() => _viewMode = set.first);
                },
              ),
            ),
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _viewMode == _LocationsViewMode.map && mapReady
              ? Column(
                  children: [
                    if (_status == 'unavailable')
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text(
                          'Location service is temporarily unavailable.',
                        ),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    Expanded(
                      child: FamilyMapView(
                        mapConfig: _mapConfig!,
                        bearerToken:
                            widget.session.enrollment!.dashboardToken,
                        httpClient: _mapHttpClient,
                        kids: _kids,
                        selectedUsername: _selectedKid,
                        trackPoints: _track?.points ?? [],
                        onKidTap: _loadTrack,
                      ),
                    ),
                  ],
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_mapConfig != null && !_mapConfig!.available)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            'Family map is not configured on this box yet. Showing coordinates only.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      if (_status == 'unavailable')
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Text(
                            'Location service is temporarily unavailable.',
                          ),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.red),
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
    final lastSeen = formatLocationAge(kid.ageSeconds);
    final hasCoords = kid.lat != null && kid.lon != null;
    return Card(
      color: selected ? TinyWebColors.bgSoft : null,
      child: ListTile(
        title: Text(
          kid.displayName.isNotEmpty ? kid.displayName : kid.username,
        ),
        subtitle: Text(
          [
            'Last seen: $lastSeen',
            if (hasCoords)
              '${kid.lat!.toStringAsFixed(5)}, ${kid.lon!.toStringAsFixed(5)}',
            if (kid.acc != null) '±${kid.acc!.round()} m',
            if (kid.batt != null) 'Battery ${kid.batt}%',
          ].join(' · '),
        ),
        onTap: () => _loadTrack(kid.username),
        trailing: hasCoords
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.directions_outlined),
                    tooltip: 'Open in Maps',
                    key: Key('open-maps-${kid.username}'),
                    onPressed: () => _openInMaps(kid),
                  ),
                  if (selected) const Icon(Icons.check),
                ],
              )
            : (selected ? const Icon(Icons.check) : null),
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
          if (when != null) _formatTrackTimestamp(when),
          if (point.acc != null) '±${point.acc!.round()} m',
          if (point.batt != null) '${point.batt}%',
        ].join(' · '),
      ),
    );
  }
}
