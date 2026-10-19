import '../api/models.dart';

class PushEnrollmentConfig {
  PushEnrollmentConfig({
    required this.unifiedGatewayUrl,
    required this.sygnalGatewayUrl,
    required this.iosAppId,
    required this.androidAppId,
    this.publicBase,
  });

  final String unifiedGatewayUrl;
  final String sygnalGatewayUrl;
  final String iosAppId;
  final String androidAppId;
  final String? publicBase;

  /// HTTPS origin for UnifiedPush / Matrix pushkeys (`https://push.<domain>`).
  String expectedPublicPushOrigin() {
    final base = publicBase?.trim();
    if (base != null && base.isNotEmpty) {
      return base.replaceAll(RegExp(r'/+$'), '');
    }
    return '';
  }

  factory PushEnrollmentConfig.fromBundle(EnrollmentBundle bundle) {
    final push = bundle.rawJson?['push'] as Map<String, dynamic>?;
    if (push == null) {
      throw StateError('push config missing from enrollment');
    }
    final unified = push['unifiedpush'] as Map<String, dynamic>? ?? {};
    final sygnal = push['sygnal'] as Map<String, dynamic>? ?? {};
    final gateway = unified['gateway_url'] as String? ?? '';
    final sygnalGw = sygnal['gateway_url'] as String? ?? '';
    if (gateway.isEmpty || sygnalGw.isEmpty) {
      throw StateError('push gateway_url missing');
    }
    return PushEnrollmentConfig(
      unifiedGatewayUrl: gateway,
      sygnalGatewayUrl: sygnalGw,
      iosAppId: sygnal['ios_app_id'] as String? ?? 'win.tinyweb.tinyweb.ios',
      androidAppId:
          sygnal['android_app_id'] as String? ?? 'win.tinyweb.tinyweb.android',
      publicBase: unified['public_base'] as String? ?? sygnal['public_base'] as String?,
    );
  }
}
