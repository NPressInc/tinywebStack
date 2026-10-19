import 'package:flutter/material.dart';

/// TinyWeb palette from `tinyweb.css`.
abstract final class TinyWebColors {
  static const blueDeep = Color(0xFF2E468F);
  static const blueSky = Color(0xFF45C3F8);
  static const blueAccent = Color(0xFF0085FA);
  static const bgSoft = Color(0xFFECF4FF);
  static const text = Color(0xFF1A2332);
  static const textMuted = Color(0xFF4A5568);
  static const border = Color(0xFFD8E2F0);
}

ThemeData tinyWebTheme() {
  const seed = TinyWebColors.blueDeep;
  final colorScheme = ColorScheme.fromSeed(
    seedColor: seed,
    primary: TinyWebColors.blueDeep,
    secondary: TinyWebColors.blueAccent,
    surface: TinyWebColors.bgSoft,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: TinyWebColors.bgSoft,
    appBarTheme: const AppBarTheme(
      backgroundColor: TinyWebColors.blueDeep,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: TinyWebColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: TinyWebColors.border),
      ),
      filled: true,
      fillColor: Colors.white,
    ),
  );
}
