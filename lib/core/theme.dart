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

/// Scheme helpers: pages must read the scheme, never the light consts
/// directly. `paper`/`ink` are light-mode values — hardcoding them pins
/// white-on-white in AMOLED while theme-aware text goes light.
bool isAmoledScheme(BuildContext context) =>
    Theme.of(context).scaffoldBackgroundColor == amoledBlack;

/// Dark-lens verdict: true under ANY dark theme (soft dark, AMOLED,
/// or a system-dark follow). Glass keys off this, not [isAmoledScheme]:
/// the amoled check only fires on pure #000, so plain dark mode fell
/// through to the white frost and hazed. AMOLED keeps its own deeper
/// veil via [isAmoledScheme] on top.
bool isDarkScheme(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

/// Dark-aware wash: artwork tone pulled toward the page background,
/// contrast-clamped at 4.5:1 against the page text color. Light pulls
/// toward paper for ink text; dark pulls toward the scaffold for light
/// text. Same pull depth either way so the color survives, not rinses.
Color archWashOf(Color? tone, {required bool dark, required bool amoled}) {
  final bg = amoled ? amoledBlack : (dark ? night : paper);
  final fallback =
      amoled ? amoledRaised : (dark ? nightRaised : paperRaised);
  final text = amoled ? amoledInk : (dark ? moon : ink);
  final base = tone ?? fallback;
  // Dark pages sit closer to the tone (tone-on-black needs less pull
  // to keep its color than tone-on-white does to stay readable).
  var pull = dark ? 0.55 : 0.3;
  var wash = Color.lerp(base, bg, pull)!;
  while (pull < 1.0 && _washContrast(text, wash) < 4.5) {
    pull += 0.05;
    wash = Color.lerp(base, bg, pull)!;
  }
  return wash;
}

double _washContrast(Color a, Color b) {
  final l1 = a.computeLuminance() + 0.05;
  final l2 = b.computeLuminance() + 0.05;
  return l1 > l2 ? l1 / l2 : l2 / l1;
}

/// AMOLED tokens: pure-black scaffold so OLED pixels stay off.
/// Moryne mechanism, own palette: the page is #000, every lifted
/// surface keeps its container tier so it separates from the page.
/// No shadows on black — depth reads via 1px stroke + tone lift.
const amoledBlack = Color(0xFF000000);
const amoledRaised = Color(0xFF1C1C1E);
const amoledHigh = Color(0xFF2C2C2E);
const amoledHighest = Color(0xFF3A3A3C);
const amoledLine = Color(0xFF38383A);
const amoledInk = Color(0xFFF5F5F7);
const amoledDim = Color(0xFF98989F);

ThemeData archTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: paper,
    colorScheme: const ColorScheme.light(
      primary: archPink,
      surface: paper,
      surfaceContainer: paperRaised,
      surfaceContainerHighest: paperRaised,
      onSurface: ink,
      onSurfaceVariant: inkDim,
    ),
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
  );
}

/// Dark themes: `amoled=false` is the soft raised dark; `amoled=true`
/// is pure #000 for OLED power saving (Moryne mechanism: black scaffold,
/// container tiers kept, surface tint killed). Both keep pink-red as the
/// single accent and body text at full tone for separation.
ThemeData archDarkTheme({bool amoled = false}) {
  final base = ThemeData.dark(useMaterial3: true);
  final bg = amoled ? amoledBlack : night;
  final raised = amoled ? amoledRaised : nightRaised;
  final high = amoled ? amoledHigh : const Color(0xFF2C2C2E);
  final body = amoled ? amoledInk : moon;
  final dim = amoled ? amoledDim : moonDim;
  final line = amoled ? amoledLine : const Color(0xFF3A3A40);
  final scheme = ColorScheme.dark(
    primary: archPink,
    surface: bg,
    surfaceContainerLowest: bg,
    surfaceContainerLow: raised,
    surfaceContainer: raised,
    surfaceContainerHigh: high,
    surfaceContainerHighest: amoled ? amoledHighest : const Color(0xFF3A3A40),
    onSurface: body,
    onSurfaceVariant: dim,
    outline: line,
    outlineVariant: line,
    surfaceTint: Colors.transparent,
  );
  final text = base.textTheme.apply(bodyColor: body, displayColor: body);
  return base.copyWith(
    scaffoldBackgroundColor: bg,
    colorScheme: scheme,
    textTheme: text,
    // Moryne mechanism: no tint lift on black, no shadow elevation.
    // Bar + sheets stay on the container tier so they part from #000.
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: body,
      elevation: 0,
      scrolledUnderElevation: amoled ? 0 : 3,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
    ),
    cardTheme: CardThemeData(color: raised, elevation: 0),
    dividerTheme: DividerThemeData(
      color: line,
      thickness: 0.5,
      space: 0.5,
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: raised,
      surfaceTintColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 640),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dialogTheme: DialogThemeData(backgroundColor: raised, elevation: 0),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: high,
      contentTextStyle: TextStyle(color: body, fontSize: 15),
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: raised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
  );
}
