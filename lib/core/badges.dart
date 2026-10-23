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
