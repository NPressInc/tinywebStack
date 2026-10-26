import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/lab_ca_config.dart';
import '../app_session.dart';
import '../brand.dart';
import '../enroll/secure_recovery_screen.dart';
import '../location/location_service.dart';
import '../widgets/quiet_hours_banner.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.session,
    this.onOpenChat,
    this.onOpenCalendar,
    this.onOpenEvents,
    this.onOpenFamily,
  });

  final AppSession session;
  final VoidCallback? onOpenChat;
  final VoidCallback? onOpenCalendar;
  final VoidCallback? onOpenEvents;
  final VoidCallback? onOpenFamily;

  @override
  Widget build(BuildContext context) {
    final profile = session.profile!;
    final isParent = profile.role == 'parent';
    final isKid = profile.role == 'kid';

    return Scaffold(
      appBar: AppBar(
        title: const Text('TinyWeb'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'remove') {
                session.removeDevice();
              } else if (value == 'recovery') {
                _openChatRecoveryKey(context);
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'recovery',
                child: Text('Chat recovery key'),
              ),
              const PopupMenuItem(
                value: 'remove',
                child: Text('Remove this device'),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: session.refreshProfile,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Hi ${profile.username}',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: TinyWebColors.text,
                    ),
                  ),
                ),
                Chip(
                  label: Text(isParent ? 'Parent' : 'Kid'),
                  backgroundColor: TinyWebColors.bgSoft,
                ),
              ],
            ),
            if (profile.quietHours.active) ...[
              const SizedBox(height: 12),
              QuietHoursBanner(profile: profile, isKid: isKid),
            ],
            if (isKid && session.enrollment?.owntracksCredentials != null) ...[
              const SizedBox(height: 12),
              _LocationSharingCard(service: session.locationService),
            ],
            const SizedBox(height: 12),
            _NotificationsToggle(session: session),
            const SizedBox(height: 20),
            _HomeTile(
              icon: Icons.chat_bubble_outline,
              title: 'Messages',
              subtitle: 'Family chat',
              onTap: onOpenChat ?? () {},
            ),
            _HomeTile(
              icon: Icons.calendar_month_outlined,
              title: 'Calendar',
              subtitle: 'Family schedules',
              onTap: onOpenCalendar ?? () {},
            ),
            if (profile.eventsEnabled && onOpenEvents != null)
              _HomeTile(
                icon: Icons.event_outlined,
                title: 'Events',
                subtitle: 'Family & federated RSVPs',
                onTap: onOpenEvents!,
              ),
            if (isParent && onOpenFamily != null)
              _HomeTile(
                icon: Icons.family_restroom_outlined,
                title: 'Family controls',
                subtitle: 'Kids: chat rules, quiet hours, events',
                onTap: onOpenFamily!,
              ),
            _HomeTile(
              icon: Icons.apps_outlined,
              title: 'Other family apps',
              subtitle: 'Server URL & login for Jellyfin and TV apps',
              onTap: () => _showOtherAppsSheet(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openChatRecoveryKey(BuildContext context) async {
    final key = await session.credentialStore.readMatrixRecoveryKey();
    if (!context.mounted) return;
    if (key != null && key.trim().isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Chat recovery key'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Save this recovery key so you can unlock encrypted messages if you sign in on another phone.',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  key,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: key));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Recovery key copied')),
                  );
                }
              },
              child: const Text('Copy key'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SecureRecoveryScreen(
                      session: session,
                      caCertPem: labCaPemForMatrix(),
                    ),
                  ),
                );
              },
              child: const Text('Enter a different key'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SecureRecoveryScreen(
            session: session,
            caCertPem: labCaPemForMatrix(),
          ),
        ),
      );
    }
  }

  void _showOtherAppsSheet(BuildContext context) {
    final profile = session.profile!;
    final enrollment = session.enrollment;
    var serverUrl = enrollment?.serverOrigin ?? '';
    if (serverUrl.isEmpty &&
        enrollment?.serverName != null &&
        enrollment!.serverName.isNotEmpty) {
      serverUrl = 'https://${enrollment.serverName}';
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 8,
          bottom: 24 + MediaQuery.of(sheetContext).padding.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Other family apps (Jellyfin, etc.)',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              const Text(
                'Optional apps like Jellyfin stay as their own separate native phone or TV apps and use your same TinyWeb login (via YunoHost).',
              ),
              const SizedBox(height: 20),
              Text(
                'Server URL',
                style: Theme.of(sheetContext).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              SelectableText(
                serverUrl,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: serverUrl));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Server URL copied')),
                    );
                  }
                },
                child: const Text('Copy server URL'),
              ),
              const SizedBox(height: 12),
              Text(
                'Username',
                style: Theme.of(sheetContext).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              SelectableText(
                profile.username,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: profile.username),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Username copied')),
                    );
                  }
                },
                child: const Text('Copy username'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationsToggle extends StatefulWidget {
  const _NotificationsToggle({required this.session});

  final AppSession session;

  @override
  State<_NotificationsToggle> createState() => _NotificationsToggleState();
}

class _NotificationsToggleState extends State<_NotificationsToggle> {
  bool _enabled = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final on = await widget.session.credentialStore.areNotificationsEnabled();
    if (mounted) {
      setState(() {
        _enabled = on;
        _loading = false;
      });
    }
    if (on) {
      final bundle = await widget.session.credentialStore.read();
      if (bundle != null) {
        await widget.session.pushService.syncFromEnrollment(bundle);
        if (mounted) {
          setState(() {});
        }
      }
    }
  }

  Future<void> _onChanged(bool value) async {
    setState(() {
      _enabled = value;
      _loading = true;
    });
    await widget.session.pushService.setNotificationsEnabled(value);
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.session.pushService.pushSetupDetail;
    final subtitle = detail != null && detail.isNotEmpty
        ? detail
        : 'Wake for new messages; text loaded on device only';
    return SwitchListTile(
      title: const Text('Notifications'),
      subtitle: Text(subtitle),
      value: _enabled,
      onChanged: _loading ? null : _onChanged,
    );
  }
}

class _LocationSharingCard extends StatelessWidget {
  const _LocationSharingCard({required this.service});

  final LocationService service;

  @override
  Widget build(BuildContext context) {
    final last = service.lastSentAt;
    final error = service.statusDetail;
    String subtitle;
    if (error != null && error.isNotEmpty) {
      subtitle = error;
    } else if (last != null) {
      subtitle = 'Last sent ${last.toLocal().toString().substring(11, 16)}';
    } else if (service.status == LocationSharingStatus.running) {
      subtitle = 'Sharing in the background';
    } else {
      subtitle = 'Starting location sharing…';
    }
    return Card(
      color: TinyWebColors.bgSoft,
      child: ListTile(
        leading: const Icon(Icons.location_on, color: TinyWebColors.blueDeep),
        title: const Text('Location sharing'),
        subtitle: Text(subtitle),
      ),
    );
  }
}

class _HomeTile extends StatelessWidget {
  const _HomeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, color: TinyWebColors.blueDeep),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
