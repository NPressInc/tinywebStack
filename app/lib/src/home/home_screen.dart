import 'package:flutter/material.dart';

import '../app_session.dart';
import '../brand.dart';
import '../widgets/quiet_hours_banner.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.session,
    this.onOpenChat,
  });

  final AppSession session;
  final VoidCallback? onOpenChat;

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
              }
            },
            itemBuilder: (ctx) => [
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
              subtitle: 'Coming soon',
              onTap: () => _showComingSoon(context, 'Calendar'),
            ),
            if (profile.eventsEnabled)
              _HomeTile(
                icon: Icons.event_outlined,
                title: 'Events',
                subtitle: 'Coming soon',
                onTap: () => _showComingSoon(context, 'Events'),
              ),
            if (isParent) ...[
              _HomeTile(
                icon: Icons.map_outlined,
                title: 'Family map',
                subtitle: 'Coming soon',
                onTap: () => _showComingSoon(context, 'Family map'),
              ),
              _HomeTile(
                icon: Icons.family_restroom_outlined,
                title: 'Family controls',
                subtitle: 'Coming soon',
                onTap: () => _showComingSoon(context, 'Family controls'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showComingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature — coming soon')),
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
