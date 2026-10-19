import '../api/models.dart';

/// Ensures map asset URLs stay on the enrolled family box (no third-party tile CDNs).
bool familyMapConfigUsesBoxOriginOnly(
  FamilyMapConfig config,
  EnrollmentBundle bundle,
) {
  final origin = _normalizedOrigin(bundle.serverOrigin);
  if (origin.isEmpty) {
    return false;
  }
  final urls = [
    config.tilesUrl,
    config.glyphsUrl,
    config.spritesUrl,
    config.styleUrl,
  ];
  for (final url in urls) {
    if (url.isEmpty) {
      continue;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return false;
    }
    final host = uri.host.toLowerCase();
    final allowed = Uri.parse(origin).host.toLowerCase();
    if (host != allowed) {
      return false;
    }
    if (!uri.scheme.startsWith('http')) {
      return false;
    }
  }
  return true;
}

String _normalizedOrigin(String serverOrigin) {
  final trimmed = serverOrigin.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  return trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}
