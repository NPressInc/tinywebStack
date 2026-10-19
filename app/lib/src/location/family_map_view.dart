import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:pmtiles/pmtiles.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart';
// Protomaps layer definitions (BSD-3 / CC0 theme data).
// ignore: implementation_imports
import 'package:vector_map_tiles_pmtiles/src/themes/v4/_package.dart' as protomaps_v4;

import '../api/models.dart';

class FamilyMapView extends StatefulWidget {
  const FamilyMapView({
    super.key,
    required this.mapConfig,
    required this.bearerToken,
    required this.httpClient,
    required this.kids,
    this.selectedUsername,
    this.trackPoints = const [],
    this.onKidTap,
  });

  final FamilyMapConfig mapConfig;
  final String bearerToken;
  final http.Client httpClient;
  final List<KidLocationSnapshot> kids;
  final String? selectedUsername;
  final List<TrackPoint> trackPoints;
  final void Function(String username)? onKidTap;

  @override
  State<FamilyMapView> createState() => _FamilyMapViewState();
}

class _FamilyMapViewState extends State<FamilyMapView> {
  PmTilesVectorTileProvider? _tileProvider;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _openTiles();
  }

  @override
  void didUpdateWidget(covariant FamilyMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mapConfig.tilesUrl != widget.mapConfig.tilesUrl ||
        oldWidget.bearerToken != widget.bearerToken) {
      _tileProvider?.archive.close();
      _tileProvider = null;
      _loadError = null;
      _openTiles();
    }
  }

  @override
  void dispose() {
    _tileProvider?.archive.close();
    super.dispose();
  }

  Future<void> _openTiles() async {
    try {
      final archive = await PmTilesArchive.fromUri(
        Uri.parse(widget.mapConfig.tilesUrl),
        client: widget.httpClient,
        headers: {'Authorization': 'Bearer ${widget.bearerToken}'},
      );
      if (!mounted) {
        await archive.close();
        return;
      }
      setState(() {
        _tileProvider = PmTilesVectorTileProvider.fromArchive(archive);
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadError = e;
      });
    }
  }

  LatLng? _center() {
    final bounds = widget.mapConfig.bounds;
    if (bounds != null && bounds.length == 4) {
      return LatLng(
        (bounds[1] + bounds[3]) / 2,
        (bounds[0] + bounds[2]) / 2,
      );
    }
    for (final kid in widget.kids) {
      if (kid.lat != null && kid.lon != null) {
        return LatLng(kid.lat!, kid.lon!);
      }
    }
    return const LatLng(0, 0);
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return Center(child: Text('Map tiles unavailable ($_loadError)'));
    }
    final provider = _tileProvider;
    if (provider == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = ProtomapsThemes(
      glyphs: widget.mapConfig.glyphsUrl,
      sprites: widget.mapConfig.spritesUrl,
    ).build(protomaps_v4.themeLight);
    final center = _center()!;
    final track = widget.trackPoints
        .where((p) => p.lat != null && p.lon != null)
        .map((p) => LatLng(p.lat!, p.lon!))
        .toList();

    return FlutterMap(
      options: MapOptions(
        initialCenter: center,
        initialZoom: 12,
        maxZoom: widget.mapConfig.maxZoom.toDouble(),
      ),
      children: [
        VectorTileLayer(
          theme: theme,
          tileProviders: TileProviders({'protomaps': provider}),
          layerMode: VectorTileLayerMode.vector,
        ),
        if (track.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: track,
                color: Theme.of(context).colorScheme.primary,
                strokeWidth: 4,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            for (final kid in widget.kids)
              if (kid.lat != null && kid.lon != null)
                Marker(
                  point: LatLng(kid.lat!, kid.lon!),
                  width: 120,
                  height: 56,
                  child: GestureDetector(
                    onTap: () => widget.onKidTap?.call(kid.username),
                    child: Column(
                      children: [
                        Icon(
                          Icons.location_pin,
                          color: kid.username == widget.selectedUsername
                              ? Theme.of(context).colorScheme.primary
                              : Colors.red,
                          size: 32,
                        ),
                        Text(
                          kid.displayName.isNotEmpty
                              ? kid.displayName
                              : kid.username,
                          style: Theme.of(context).textTheme.labelSmall,
                          textAlign: TextAlign.center,
                        ),
                        if (kid.ageSeconds != null)
                          Text(
                            '${kid.ageSeconds}s ago',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
        RichAttributionWidget(
          attributions: [
            TextSourceAttribution(widget.mapConfig.attribution),
          ],
        ),
      ],
    );
  }
}
