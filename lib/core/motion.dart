import 'package:flutter/material.dart';

/// One motion language for the whole app. Durations express distance and
/// consequence; exits run faster than entrances; nothing bounces by reflex.
abstract final class Motion {
  static const feedback = Duration(milliseconds: 120);
  static const stateChange = Duration(milliseconds: 220);
  static const overlay = Duration(milliseconds: 350);
  static const focal = Duration(milliseconds: 650);

  static const arrival = Cubic(0.16, 1.0, 0.3, 1.0);
  static const settle = Curves.easeOutCubic;

  /// True when the system asked for reduced motion: fades and state
  /// changes only. Springs become cuts, entrances become fades.
  static bool reduced(BuildContext context) => MediaQuery.disableAnimationsOf(context);

  /// Stagger budget for sibling reveals: capped so lists never cascade forever.
  static Duration stagger(int index, {int capMs = 300}) =>
      Duration(milliseconds: (index * 40).clamp(0, capMs));
}

/// Reusable focal entrance: fade + rise once, then stay put.
class FocalEntrance extends StatefulWidget {
  final Widget child;
  final int index;

  const FocalEntrance({super.key, required this.child, this.index = 0});

  @override
  State<FocalEntrance> createState() => _FocalEntranceState();
}

class _FocalEntranceState extends State<FocalEntrance> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _fade;
  late final Animation<Offset> _rise;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: Motion.focal);
    _fade = CurvedAnimation(parent: _c, curve: const Interval(0.0, 0.7, curve: Curves.easeOut));
    _rise = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(CurvedAnimation(parent: _c, curve: Motion.arrival));
    Future.delayed(Motion.stagger(widget.index), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return widget.child;
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _rise, child: widget.child),
    );
  }
}
