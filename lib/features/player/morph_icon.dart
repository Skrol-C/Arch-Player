import 'dart:async';

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

/// Cascade entrance: the house row-arrival for menus AND sheets.
/// Each row springs out once on open (16px rise, overshoot ease,
/// fading in), staggered by [delayMs]. Mount-time only (one timer,
/// one animation, then rests): zero per-tick cost. Reduced-motion
/// renders the child straight, no timer. States persist across
/// rebuilds, so only newly mounted rows ever replay.
class CascadeIn extends StatefulWidget {
  final int delayMs;
  final Widget child;
  const CascadeIn({super.key, required this.delayMs, required this.child});

  @override
  State<CascadeIn> createState() => _CascadeInState();
}

class _CascadeInState extends State<CascadeIn> {
  bool _go = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // No context reads here (MediaQuery is illegal before initState
    // completes) - the reduced-motion branch lives in build.
    _timer = Timer(Duration(milliseconds: widget.delayMs), () {
      if (mounted) setState(() => _go = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduced-motion renders the child straight: no timer chase,
    // no tween, same pixels as the animation's end state.
    if (Motion.reduced(context)) return widget.child;
    if (!_go) return Opacity(opacity: 0, child: widget.child);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutBack,
      builder: (context, v, _) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 16 * (1 - v)),
          child: widget.child,
        ),
      ),
    );
  }
}
