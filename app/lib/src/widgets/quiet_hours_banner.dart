import 'package:flutter/material.dart';

import '../api/models.dart';
import '../brand.dart';

class QuietHoursBanner extends StatelessWidget {
  const QuietHoursBanner({
    super.key,
    required this.profile,
    required this.isKid,
  });

  final AppMeProfile profile;
  final bool isKid;

  @override
  Widget build(BuildContext context) {
    final end = profile.quietHours.windowEnd ?? 'later';
    final text = isKid
        ? 'Quiet hours — messages are paused until $end'
        : 'Quiet hours are active';

    return Card(
      color: TinyWebColors.blueSky.withValues(alpha: 0.25),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.nightlight_round, color: TinyWebColors.blueDeep),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}
