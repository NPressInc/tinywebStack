import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/api/models.dart';
import 'package:tinyweb/src/location/map_config_policy.dart';

FamilyDiscovery _discovery() => FamilyDiscovery(
      serverOrigin: 'https://family.example',
      enrollUrl: '/family/api/app/enroll',
    );

EnrollmentBundle _bundle() => EnrollmentBundle(
      deviceId: 'd',
      username: 'parent1',
      role: 'parent',
      mxid: '@parent1:family.example',
      serverName: 'family.example',
      dashboardToken: 'token',
      apiBase: '/family/api',
      serverOrigin: 'https://family.example',
      discovery: _discovery(),
    );

void main() {
  test('map config URLs must stay on box origin', () {
    final config = FamilyMapConfig(
      available: true,
      attribution: '© OpenStreetMap contributors, Protomaps',
      maxZoom: 14,
      flavor: 'light',
      tilesUrl: 'https://family.example/family/tiles/basemap.pmtiles',
      glyphsUrl:
          'https://family.example/family/tiles/fonts/{fontstack}/{range}.pbf?t=x',
      spritesUrl: 'https://family.example/family/tiles/sprites/v4/light?t=x',
      styleUrl: 'https://family.example/family/tiles/style.json?t=x',
      bounds: [-105, 39, -104, 40],
    );
    expect(familyMapConfigUsesBoxOriginOnly(config, _bundle()), isTrue);
  });

  test('rejects third-party tile hosts', () {
    final config = FamilyMapConfig(
      available: true,
      attribution: 'x',
      maxZoom: 14,
      flavor: 'light',
      tilesUrl: 'https://tile.openstreetmap.org/1/1/1.png',
      glyphsUrl: 'https://family.example/family/tiles/fonts/x',
      spritesUrl: 'https://family.example/family/tiles/sprites/v4/light',
      styleUrl: 'https://family.example/family/tiles/style.json',
    );
    expect(familyMapConfigUsesBoxOriginOnly(config, _bundle()), isFalse);
  });
}
