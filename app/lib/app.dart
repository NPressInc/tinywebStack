import 'package:flutter/material.dart';

import 'src/app_session.dart';
import 'src/brand.dart';
import 'src/enroll/enroll_screen.dart';
import 'src/enroll/secure_recovery_screen.dart';
import 'src/shell/main_shell.dart';

class TinyWebApp extends StatefulWidget {
  const TinyWebApp({super.key, this.session});

  final AppSession? session;

  @override
  State<TinyWebApp> createState() => _TinyWebAppState();
}

class _TinyWebAppState extends State<TinyWebApp> {
  late final AppSession _session = widget.session ?? AppSession();

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    _session.bootstrap();
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
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
      case AppRoute.enroll:
        return EnrollScreen(
          session: _session,
          bannerMessage: _session.enrollBannerMessage,
        );
      case AppRoute.secureChats:
        return SecureRecoveryScreen(session: _session);
      case AppRoute.home:
        return MainShell(session: _session);
    }
  }
}
