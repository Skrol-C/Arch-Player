import 'package:flutter/material.dart';

import '../../core/motion.dart';

/// Generic toggle morph: the glyph crossfades with a spring
/// scale-pop whenever [iconKey] changes. The house animation for
/// every toggle - no custom painters, one motion, everywhere.
class MorphIcon extends StatelessWidget {
  final Object iconKey;
  final Widget child;

  const MorphIcon({super.key, required this.iconKey, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration:
          Motion.reduced(context) ? Duration.zero : Motion.stateChange,
      transitionBuilder: (child, animation) {
        final scale = animation.drive(Tween(begin: 0.7, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOutBack)));
        return ScaleTransition(
            scale: scale,
            child: FadeTransition(opacity: animation, child: child));
      },
      child: KeyedSubtree(key: ValueKey(iconKey), child: child),
    );
  }
}
