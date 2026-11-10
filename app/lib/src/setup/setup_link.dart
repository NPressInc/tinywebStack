/// One-time setup code from the card in the box.
///
/// The secret is the URL fragment (`#code=`), never a query parameter.
class SetupCodeParse {
  const SetupCodeParse({this.code, this.error});

  final String? code;
  final String? error;

  bool get isOk => code != null && (error == null || error!.isEmpty);
}

final RegExp _setupToken = RegExp(r'^[A-Za-z0-9_-]{8,128}$');

/// True when [raw] is a setup link, even if the code itself is missing or misplaced.
bool looksLikeSetupLink(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) {
    return false;
  }
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  if (scheme == 'tinyweb' && host == 'setup') {
    return true;
  }
  if (scheme == 'https' && host == 'tinyweb.win') {
    var path = uri.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path == '/setup';
  }
  return false;
}

/// Reads a typed token or a setup link. Does not contact tinyweb.win.
SetupCodeParse parseSetupCode(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return const SetupCodeParse(
      error: 'Enter the setup code from the card in the box.',
    );
  }
  if (text.contains('://') || text.startsWith('tinyweb:')) {
    final uri = Uri.tryParse(text);
    if (uri == null || !looksLikeSetupLink(text)) {
      return const SetupCodeParse(error: 'That is not a TinyWeb setup code.');
    }
    if (uri.queryParameters.containsKey('code')) {
      return const SetupCodeParse(
        error: 'That link puts the setup code in the wrong place. Scan the card again.',
      );
    }
    final token = uri.fragment.isEmpty
        ? null
        : Uri.splitQueryString(uri.fragment)['code']?.trim();
    if (token == null || token.isEmpty) {
      return const SetupCodeParse(error: 'That setup link has no code.');
    }
    return _tokenOrError(token);
  }
  if (text.contains('/') || text.contains('?') || text.contains('#') || text.contains(' ')) {
    return const SetupCodeParse(error: 'That is not a TinyWeb setup code.');
  }
  return _tokenOrError(text);
}

SetupCodeParse _tokenOrError(String token) {
  if (!_setupToken.hasMatch(token)) {
    return const SetupCodeParse(
      error: 'That setup code does not look right. Scan the card again.',
    );
  }
  return SetupCodeParse(code: token);
}
