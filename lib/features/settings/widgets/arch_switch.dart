import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/motion.dart';
import '../../../core/theme.dart';

/// Arch-styled switch: a pink-red pill track with a white knob that
/// slides on a spring. Original control — reads the boolean it is
/// given, reports taps, nothing more.
class ArchSwitch extends StatefulWidget {
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
  State<ArchSwitch> createState() => _ArchSwitchState();
}

class _ArchSwitchState extends State<ArchSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: widget.value ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(ArchSwitch old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      if (Motion.reduced(context)) {
        _c.value = widget.value ? 1 : 0;
      } else if (widget.value) {
        _c.forward();
      } else {
        _c.reverse();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark =
        Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onChanged(!widget.value);
      },
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          return SizedBox(
            width: 52 * widget.scale,
            height: 30 * widget.scale,
            child: CustomPaint(
              painter: _SwitchPainter(
                t: t,
                on: dark
                    ? const Color(0xFF3A3A3F)
                    : const Color(0xFFE3E3E6),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SwitchPainter extends CustomPainter {
  final double t;
  final Color on;

  _SwitchPainter({required this.t, required this.on});

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromLTRBR(
      0,
      0,
      size.width,
      size.height,
      Radius.circular(size.height / 2),
    );
    final base = Color.lerp(on, archPink, t)!;
    canvas.drawRRect(track, Paint()..color = base);
    // Knob: white, slides edge to edge with a springy overshoot baked
    // into the animation curve (controller drives linear t; the
    // overshoot comes from the ease below).
    final eased = t * t * (3 - 2 * t);
    final r = size.height / 2 - 3;
    final cx = 3 + r + eased * (size.width - 6 - r * 2);
    canvas.drawCircle(
      Offset(cx, size.height / 2),
      r,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_SwitchPainter old) =>
      old.t != t || old.on != on;
}
