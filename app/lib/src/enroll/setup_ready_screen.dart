import 'package:flutter/material.dart';

import '../brand.dart';
import 'setup_checklist.dart';

class SetupReadyScreen extends StatelessWidget {
  const SetupReadyScreen({
    super.key,
    required this.checklist,
    required this.onContinue,
  });

  final SetupChecklist checklist;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TinyWeb')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            checklist.headline,
            key: const Key('setup-ready-title'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: TinyWebColors.text,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          Text(checklist.subtitle),
          const SizedBox(height: 16),
          for (final item in checklist.items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                item.ready ? Icons.check_circle : Icons.flag_outlined,
                color: item.ready ? TinyWebColors.blueDeep : Theme.of(context).colorScheme.error,
              ),
              title: Text(item.title),
              subtitle: Text(item.detail),
            ),
          if (checklist.remaining != null) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(checklist.remaining!),
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('setup-continue'),
            onPressed: onContinue,
            child: Text(checklist.continueLabel),
          ),
        ],
      ),
    );
  }
}
