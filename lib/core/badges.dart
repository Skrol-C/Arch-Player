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
