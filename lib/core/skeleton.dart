import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';

/// Ghost placeholders for loading states: the shape of what's
/// coming, never a spinner bar. A slow opacity pulse suggests
/// progress; reduced-motion renders static ghosts. Mornye's rule,
/// our skin: skeletons mirror the loaded layout one-for-one so the
/// page never jumps when data lands.
class _Pulse extends StatefulWidget {
  final Widget child;
  const _Pulse({required this.child});

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    // No MediaQuery reads here: inherited widgets aren't available
    // until after initState completes (that was a red-screen crash).
    // The reduced-motion decision lives in didChangeDependencies.
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      if (_running) {
        _running = false;
        _c.stop();
      }
      _c.value = 1.0;
    } else if (!_running) {
      _running = true;
      _c.repeat(reverse: true);
    }
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
      opacity: _c.drive(Tween(begin: 1.0, end: 0.45)),
      child: widget.child,
    );
  }
}

/// One ghost block: raised fill, continuous corners.
class GhostBlock extends StatelessWidget {
  final double width;
  final double height;
  final double radius;

  const GhostBlock({
    super.key,
    required this.width,
    required this.height,
    this.radius = 8,
  });

  @override
  Widget build(BuildContext context) {
    return _Pulse(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: paperRaised,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

/// Ghost track row: 52 art + title bar + subtitle bar. Fixed height
/// so pagers can size off it without overflow math.
class GhostTrackRow extends StatelessWidget {
  const GhostTrackRow({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        children: [
          GhostBlock(width: 52, height: 52, radius: 10),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                GhostBlock(width: 180, height: 14, radius: 4),
                SizedBox(height: 8),
                GhostBlock(width: 120, height: 12, radius: 4),
              ],
            ),
          ),
          GhostBlock(width: 40, height: 14, radius: 4),
        ],
      ),
    );
  }
}

/// Ghost fan-hub card: cover stack + label dots, same 195 footprint
/// as the real hubs.
class GhostFanCard extends StatelessWidget {
  const GhostFanCard({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(right: 20),
      child: SizedBox(
        width: 175,
        child: Column(
          children: [
            GhostBlock(width: 175, height: 150, radius: 16),
            SizedBox(height: 10),
            GhostBlock(width: 90, height: 14, radius: 4),
            SizedBox(height: 6),
            GhostBlock(width: 40, height: 11, radius: 4),
          ],
        ),
      ),
    );
  }
}

/// Ghost section title: one voice-sized bar.
class GhostTitle extends StatelessWidget {
  const GhostTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GhostBlock(width: 140, height: 24, radius: 6),
      ),
    );
  }
}
