import 'package:flutter/material.dart';

/// Single palette. White day-mode + Apple pink-red. No Material Theme
/// improvisation anywhere else: every color below is the law.
const archPink = Color(0xFFFC3C44);
const archPinkDim = Color(0xFFB3122E);
const paper = Color(0xFFFFFFFF);
const paperRaised = Color(0xFFF6F6F8);
const ink = Color(0xFF0B0B0D);
const inkDim = Color(0xFF6E6E73);

ThemeData archTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: paper,
    colorScheme: const ColorScheme.light(
      primary: archPink,
      surface: paper,
      surfaceContainerHighest: paperRaised,
      onSurface: ink,
      onSurfaceVariant: inkDim,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: ink,
      displayColor: ink,
    ),
  );
}
