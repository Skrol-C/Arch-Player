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
///
/// Order is part of the contract: an artist's face is `hash % length`,
/// so adding OR removing an entry reshuffles every name. Append; never
/// insert. House names hide the real families (noted inline) - the
/// licences live beside the files as fonts/OFL-*.txt.
const displayVoices = [
  // shipped
  'ArchGrotesk', // Oswald
  'ArchSerif', // Playfair Display
  'ArchGeometric', // Poppins
  'ArchBlack', // Anton
  'ArchDidone', // Abril Fatface
  'ArchMasthead', // Archivo Black
  'ArchPoster', // Bebas Neue
  'ArchSlab', // Alfa Slab One
  'ArchUrban', // Bungee
  'ArchChunk', // Titan One
  // display, odd
  'ArchCaveat', // Caveat
  'ArchPirata', // Pirata One
  'ArchMono', // Space Mono
  'ArchCinzel', // Cinzel
  'ArchMarker', // Permanent Marker
  'ArchBowlby', // Bowlby One
  'ArchRighteous', // Righteous
  'ArchYeseva', // Yeseva One
  'ArchSyncopate', // Syncopate
  // editorial serif
  'ArchBaskerville', // Libre Baskerville
  'ArchGaramond', // EB Garamond
  'ArchCormorant', // Cormorant Garamond
  'ArchLora', // Lora
  'ArchMerriweather', // Merriweather
  'ArchDMSerif', // DM Serif Display
  'ArchBodoni', // Bodoni Moda
  'ArchZilla', // Zilla Slab
  'ArchBitter', // Bitter
  // sans / grotesque
  'ArchNarrow', // Archivo Narrow
  'ArchBarlow', // Barlow Condensed
  'ArchRubik', // Rubik
  'ArchWork', // Work Sans
  'ArchSpaceGrotesk', // Space Grotesk
  'ArchManrope', // Manrope
  'ArchOutfit', // Outfit
  'ArchLexend', // Lexend
  'ArchSyne', // Syne ExtraBold
  'ArchUnbounded', // Unbounded
  // condensed / tall
  'ArchFjalla', // Fjalla One
  'ArchTeko', // Teko
  'ArchSaira', // Saira Condensed
  'ArchShoulders', // Big Shoulders Display
  // decorative
  'ArchBangers', // Bangers
  'ArchLuckiest', // Luckiest Guy
  'ArchPassion', // Passion One
  'ArchShrikhand', // Shrikhand
  'ArchRye', // Rye
  'ArchUltra', // Ultra
  'ArchGraduate', // Graduate
  'ArchMegrim', // Megrim
  // script / hand
  'ArchPacifico', // Pacifico
  'ArchLobster', // Lobster
  'ArchYellowtail', // Yellowtail
  'ArchVibes', // Great Vibes
  'ArchDancing', // Dancing Script
  'ArchKaushan', // Kaushan Script
  'ArchAllura', // Allura
  'ArchCourgette', // Courgette
  // mono / techno
  'ArchOrbitron', // Orbitron
  'ArchAudiowide', // Audiowide
];

String artistVoiceOf(String name) {
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return displayVoices[h % displayVoices.length];
}

/// Per-voice letterspacing: condensed voices breathe open, high-contrast
/// serifs tuck in, scripts and mono sit neutral.
double voiceSpacing(String voice) => switch (voice) {
  'ArchGrotesk' ||
  'ArchBlack' ||
  'ArchPoster' ||
  'ArchNarrow' ||
  'ArchBarlow' ||
  'ArchSaira' ||
  'ArchShoulders' ||
  'ArchTeko' ||
  'ArchFjalla' ||
  'ArchUltra' ||
  'ArchSyncopate' ||
  'ArchUnbounded' =>
    0.5,
  'ArchSerif' ||
  'ArchDidone' ||
  'ArchBodoni' ||
  'ArchDMSerif' ||
  'ArchCormorant' ||
  'ArchBaskerville' ||
  'ArchGaramond' ||
  'ArchZilla' ||
  'ArchBitter' =>
    -0.5,
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
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
  );
}
