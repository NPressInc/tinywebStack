// Build Matrix `POST /pushers/set` bodies (unit-tested; mirrors Rust SDK).

Map<String, dynamic> buildHttpPusherSetBody({
  required String appId,
  required String pushkey,
  required String gatewayUrl,
  String lang = 'en',
  String appDisplayName = 'TinyWeb',
  String deviceDisplayName = 'TinyWeb device',
}) {
  return {
    'pushkey': pushkey,
    'app_id': appId,
    'kind': 'http',
    'app_display_name': appDisplayName,
    'device_display_name': deviceDisplayName,
    'lang': lang,
    'data': {
      'url': gatewayUrl,
      'format': 'event_id_only',
    },
  };
}

Map<String, dynamic> buildHttpPusherDeleteBody({
  required String appId,
  required String pushkey,
}) {
  return {
    'pushkey': pushkey,
    'app_id': appId,
    'kind': null,
  };
}
