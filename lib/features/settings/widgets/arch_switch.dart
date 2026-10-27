import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../../core/theme.dart';

/// House switch: the package clear-pill thumb, pink track when on.
/// Single home for every toggle in the app - settings, needle,
/// doctor, folders. Drag to an edge and it flips early; the thumb
/// swells to glass under your finger.
class ArchSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final double scale;

  const ArchSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSwitch(
      value: value,
      onChanged: onChanged,
      // Pink = on, everywhere. The swell paints outside the footprint
      // and scrolling lists clip - hence the reserved room.
      activeColor: archPink,
      reserveSwellRoom: true,
      layout: LiquidGlassSwitchLayout().scaled(scale),
    );
  }
}
