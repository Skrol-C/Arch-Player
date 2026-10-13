import 'package:flutter/material.dart';

/// Single palette. White day-mode + Apple pink-red. No Material Theme
/// improvisation anywhere else: every color below is the law.
const archPink = Color(0xFFFC3C44);
const archPinkDim = Color(0xFFB3122E);
const paper = Color(0xFFFFFFFF);
const paperRaised = Color(0xFFF6F6F8);
const ink = Color(0xFF0B0B0D);
const inkDim = Color(0xFF6E6E73);

/// Night tokens: reserved for the future dark mode (white is phase
/// one, not forever). Deliberately unused right now - when dark
/// lands, these power it; nothing gets invented twice.
const night = Color(0xFF1B1B1E);
const nightRaised = Color(0xFF26262B);
const moon = Color(0xFFF5F5F7);
const moonDim = Color(0xFF9C9CA3);

/// Display-voice rotation for hero names (artist + album). Stable per
/// name forever (plain code-unit hash - String.hashCode is not stable
/// across runs), no storage, no network. Missing glyphs (CJK, Arabic...)
/// fall back to system type automatically.
const displayVoices = [
  'ArchGrotesk',
  'ArchSerif',
  'ArchGeometric',
  'ArchBlack',
  'ArchDidone',
  'ArchMasthead',
  'ArchPoster',
  'ArchSlab',
  'ArchUrban',
  'ArchChunk',
];

String artistVoiceOf(String name) {
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return displayVoices[h % displayVoices.length];
}

/// Per-voice letterspacing: condensed voices breathe open, serifs tuck
/// in, the rest sit neutral.
double voiceSpacing(String voice) => switch (voice) {
      'ArchGrotesk' || 'ArchBlack' || 'ArchPoster' => 0.5,
      'ArchSerif' || 'ArchDidone' => -0.5,
      _ => 0.0,
    };

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
