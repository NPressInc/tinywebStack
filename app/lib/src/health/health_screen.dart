import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app_session.dart';
import '../brand.dart';

class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  Future<HealthReport>? _report;

  @override
  void initState() {
    super.initState();
    if (_isParent) {
      _report = widget.session.fetchHealth();
    }
  }

  bool get _isParent => widget.session.profile?.role == 'parent';

  Future<void> _reload() async {
    final next = widget.session.fetchHealth();
    setState(() {
      _report = next;
    });
    try {
      await next;
    } catch (_) {
      // FutureBuilder renders the error.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isParent) {
      return Scaffold(
        appBar: AppBar(title: const Text('Home health')),
        body: const Center(child: Text('Only parents can check the home.')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Home health')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<HealthReport>(
          future: _report,
          builder: (context, snapshot) {
            if (_report == null || snapshot.connectionState != ConnectionState.done) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  Center(child: CircularProgressIndicator()),
                ],
              );
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(24),
                children: const [
                  Text('Could not check the home just now. Pull to try again.'),
                ],
              );
            }
            final report = snapshot.data!;
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  report.overallLabel,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: TinyWebColors.text,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Looking only — nothing is restarted from here.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: TinyWebColors.textMuted,
                      ),
                ),
                const SizedBox(height: 12),
                for (final check in report.checks)
                  Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      title: Text(check.title),
                      subtitle: Text(
                        check.hint.isEmpty
                            ? check.summary
                            : '${check.summary}\n${check.hint}',
                      ),
                      trailing: Text(
                        check.statusLabel,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: _statusColor(check.status),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'ok':
        return const Color(0xFF0F7A32);
      case 'warning':
        return const Color(0xFF8A5B00);
      case 'not_installed':
        return TinyWebColors.textMuted;
      default:
        return const Color(0xFFB42318);
    }
  }
}
