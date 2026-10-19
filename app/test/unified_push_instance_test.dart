import 'package:flutter_test/flutter_test.dart';
import 'package:tinyweb/src/push/unified_push_instance.dart';

void main() {
  test('generateUnifiedPushInstanceId yields distinct values', () {
    final a = generateUnifiedPushInstanceId();
    final b = generateUnifiedPushInstanceId();
    expect(a, startsWith('up'));
    expect(b, startsWith('up'));
    expect(a.length, greaterThanOrEqualTo(14));
    expect(a, isNot(equals(b)));
  });
}
