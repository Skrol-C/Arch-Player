import 'package:flutter/material.dart';

import 'theme.dart';

/// Release-type mark (SINGLE / EP): solid ink box, white caps.
/// Albums are the default and stay unbadged. Rendered only when the
/// provider said single or EP — never guessed.
class TypeBadge extends StatelessWidget {
  final String label;

  const TypeBadge({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: ink,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          height: 1.2,
        ),
      ),
    );
  }
}

/// Containment mark for select mode: black badge naming the playlist
/// holding the song ("Summer 26"), first name + count when several
/// ("Summer 26 +2"). Empty = no badge. Gated on select mode by
/// callers — normal browsing stays clean.
class ContainedBadge extends StatelessWidget {
  final List<String> names;

  const ContainedBadge({super.key, required this.names});

  @override
  Widget build(BuildContext context) {
    if (names.isEmpty) return const SizedBox.shrink();
    var first = names.first;
    if (first.length > 14) first = '${first.substring(0, 13)}…';
    final label = names.length == 1 ? first : '$first +${names.length - 1}';
    return TypeBadge(label: label);
  }
}

/// Harmonic key mark: Camelot code on its wheel color (8A lands
/// green). Minor keys run deep, majors run brighter. Unknown codes
/// fall back to the ink box. Borrowed grammar, own wheel — Spotify
/// never published its palette.
class KeyBadge extends StatelessWidget {
  /// Traktor open key: '8m' / '8d'.
  final String openKey;

  const KeyBadge({super.key, required this.openKey});

  static ({int number, bool minor})? _parse(String open) {
    final m =
        RegExp(r'^(\d{1,2})\s*([md])$', caseSensitive: false)
            .firstMatch(open.trim());
    if (m == null) return null;
    final num = int.tryParse(m.group(1)!);
    if (num == null || num < 1 || num > 12) return null;
    return (number: num, minor: m.group(2)!.toLowerCase() == 'm');
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parse(openKey);
    if (parsed == null) return TypeBadge(label: openKey);
    final hue = ((parsed.number - 1) * 30 + 270) % 360.0;
    final bg = HSLColor.fromAHSL(
      1.0,
      hue,
      0.55,
      parsed.minor ? 0.38 : 0.48,
    ).toColor();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '${parsed.number}${parsed.minor ? 'A' : 'B'}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          height: 1.2,
        ),
      ),
    );
  }
}
