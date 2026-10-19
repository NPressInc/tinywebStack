import 'dart:math';

/// Unguessable UnifiedPush instance id (ntfy topic); must match `up*` ACL on the box.
String generateUnifiedPushInstanceId() {
  const chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final r = Random.secure();
  return 'up${List.generate(16, (_) => chars[r.nextInt(chars.length)]).join()}';
}
