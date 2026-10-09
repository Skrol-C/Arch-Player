import 'package:flutter/material.dart';

/// Arch tokens: red on near-black. Red = accents only.
const archRed = Color(0xFFFA1744);
const archRedDim = Color(0xFF8E0F28);
const ink = Color(0xFF0B0B0D);
const inkRaised = Color(0xFF1C1C1F);
const inkTextDim = Color(0xFF9C9CA3);

ThemeData archTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: ink,
    colorScheme: const ColorScheme.dark(
      primary: archRed,
      surface: ink,
      surfaceContainerHighest: inkRaised,
      onSurfaceVariant: inkTextDim,
    ),
  );
}
