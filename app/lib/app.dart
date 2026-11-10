import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'src/api/lab_ca_config.dart';
import 'src/api/models.dart';
import 'src/app_session.dart';
import 'src/brand.dart';
import 'src/enroll/enroll_screen.dart';
import 'src/enroll/secure_recovery_screen.dart';
import 'src/enroll/setup_checklist.dart';
import 'src/enroll/setup_ready_screen.dart';
import 'src/location/location_explainer_screen.dart';
import 'src/setup/setup_link.dart';
import 'src/setup/unbox_screen.dart';
import 'src/shell/main_shell.dart';

class TinyWebApp extends StatefulWidget {
  const TinyWebApp({super.key, this.session});

  final AppSession? session;

  @override
  State<TinyWebApp> createState() => _TinyWebAppState();
}

class _TinyWebAppState extends State<TinyWebApp> {
  late final AppSession _session = widget.session ?? AppSession();
  String? _enrollLink;
  String? _setupCode;
  String? _setupLinkError;
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    _session.bootstrap();
    _listenForEnrollLinks();
  }

  /// OS links are optional. If the plugin is missing, the enroll form still works.
  Future<void> _listenForEnrollLinks() async {
    try {
      final appLinks = AppLinks();
      final initial = await appLinks.getInitialLink();
      if (!mounted) {
        return;
      }
      if (initial != null) {
        _takeLink(initial.toString());
      }
      _linkSub = appLinks.uriLinkStream.listen((uri) {
        if (!mounted) {
          return;
        }
        _takeLink(uri.toString());
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _takeLink(String raw) {
    if (looksLikeSetupLink(raw)) {
      final parsed = parseSetupCode(raw);
      setState(() {
        if (parsed.code != null) {
          _setupCode = parsed.code;
        }
        _setupLinkError = parsed.error;
        _enrollLink = null;
      });
      _session.openUnbox();
      return;
    }
    setState(() => _enrollLink = raw);
    _session.openExistingFamilyEnroll();
  }

  void _onSessionChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TinyWeb',
      theme: tinyWebTheme(),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    switch (_session.route) {
      case AppRoute.loading:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case AppRoute.unbox:
        return UnboxScreen(
          session: _session,
          initialCode: _setupCode,
          initialError: _setupLinkError,
        );
      case AppRoute.enroll:
        return EnrollScreen(
          session: _session,
          bannerMessage: _session.enrollBannerMessage,
          initialLink: _enrollLink,
        );
      case AppRoute.setupReady:
        final bundle = _session.enrollment;
        if (bundle == null) {
          return EnrollScreen(
            session: _session,
            bannerMessage: _session.enrollBannerMessage,
            initialLink: _enrollLink,
          );
        }
        return SetupReadyScreen(
          checklist: describeSetup(
            bundle,
            needsRecovery: bundle.matrixEnrollment.isOk,
            needsLocation:
                bundle.isKid && bundle.owntracksCredentials != null,
          ),
          onContinue: () {
            _session.continueFromSetupChecklist();
          },
        );
      case AppRoute.secureChats:
        return SecureRecoveryScreen(
          session: _session,
          caCertPem: labCaPemForMatrix(),
        );
      case AppRoute.locationExplainer:
        return LocationExplainerScreen(session: _session);
      case AppRoute.home:
        return MainShell(session: _session);
    }
  }
}
