import 'package:flutter/material.dart';

import '../app_session.dart';
import '../brand.dart';

class LocationExplainerScreen extends StatelessWidget {
  const LocationExplainerScreen({super.key, required this.session});

  final AppSession session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Location sharing')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.location_on_outlined, size: 56, color: TinyWebColors.blueDeep),
            const SizedBox(height: 16),
            Text(
              'Your parents can see where this phone is. Sharing runs in the background.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'TinyWeb sends location to your family\'s own server. You cannot turn this off in the app.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => session.acknowledgeLocationSharing(),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}
