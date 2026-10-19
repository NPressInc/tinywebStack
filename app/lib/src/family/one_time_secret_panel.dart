import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'enroll_qr_card.dart';

/// Shows a one-time secret (password, code, invite token) with copy — never persisted.
class OneTimeSecretPanel extends StatelessWidget {
  const OneTimeSecretPanel({
    super.key,
    required this.title,
    required this.secret,
    this.hint,
    this.qrPayload,
    this.secondaryLabel,
    this.secondarySecret,
  });

  final String title;
  final String secret;
  final String? hint;
  final String? qrPayload;
  final String? secondaryLabel;
  final String? secondarySecret;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (hint != null) ...[
              const SizedBox(height: 8),
              Text(hint!, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            SelectableText(
              secret,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: secret.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: secret));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied')),
                      );
                    },
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
            ),
            if (secondaryLabel != null && secondarySecret != null) ...[
              const SizedBox(height: 16),
              Text(secondaryLabel!),
              const SizedBox(height: 8),
              SelectableText(
                secondarySecret!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: secondarySecret!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy link'),
              ),
            ],
            if (qrPayload != null && qrPayload!.isNotEmpty) ...[
              const SizedBox(height: 16),
              EnrollQrCard(data: qrPayload!),
            ],
            const SizedBox(height: 8),
            Text(
              'This is shown once. TinyWeb does not save it on this device.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
