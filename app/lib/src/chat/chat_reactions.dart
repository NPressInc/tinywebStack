import 'package:flutter/material.dart';

import 'chat_models.dart';

/// iOS default tapback emojis.
const kTapbackEmojis = ['❤️', '👍', '👎', '😂', '‼️', '❓'];

class ReactionStacks extends StatelessWidget {
  const ReactionStacks({
    super.key,
    required this.reactions,
    required this.isOwn,
    this.onTapStack,
  });

  final List<ChatReaction> reactions;
  final bool isOwn;
  final void Function(String emoji, List<ChatReaction> reactors)? onTapStack;

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) {
      return const SizedBox.shrink();
    }
    final grouped = <String, List<ChatReaction>>{};
    for (final r in reactions) {
      grouped.putIfAbsent(r.emoji, () => []).add(r);
    }
    return Positioned(
      top: -6,
      left: isOwn ? null : 8,
      right: isOwn ? 8 : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in grouped.entries)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: GestureDetector(
                onTap: () => onTapStack?.call(entry.key, entry.value),
                child: Container(
                  key: ValueKey('reaction-${entry.key}'),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.black12),
                    boxShadow: const [
                      BoxShadow(color: Colors.black12, blurRadius: 2, offset: Offset(0, 1)),
                    ],
                  ),
                  child: Text(
                    entry.value.length > 1 ? '${entry.key} ${entry.value.length}' : entry.key,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
