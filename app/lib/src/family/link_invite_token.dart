/// Extract a household link-invite token from pasted text or invite URLs.
String? parseLinkInviteToken(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  if (!trimmed.contains('token=') && !trimmed.contains('?')) {
    return trimmed;
  }
  Uri? uri = Uri.tryParse(trimmed);
  if (uri == null && trimmed.contains('token=')) {
    uri = Uri.tryParse('https://placeholder$trimmed');
  }
  final fromQuery = uri?.queryParameters['token'];
  if (fromQuery != null && fromQuery.isNotEmpty) {
    return fromQuery;
  }
  return trimmed;
}
