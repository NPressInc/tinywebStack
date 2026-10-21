import 'package:flutter/material.dart';

/// iOS Messages–style chat palette.
abstract final class ChatColors {
  static const ownBubble = Color(0xFF0A84FF);
  static const ownText = Colors.white;

  static Color otherBubble(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark ? const Color(0xFF3A3A3C) : const Color(0xFFE9E9EB);
  }

  static Color otherText(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark ? Colors.white : const Color(0xFF1C1C1E);
  }

  static Color typingBubble(BuildContext context) => otherBubble(context);
}
