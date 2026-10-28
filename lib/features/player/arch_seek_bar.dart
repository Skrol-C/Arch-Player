import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../library/song_row.dart' show fmtDuration;

/// House seekbar: a plain 5px track with a strict left-to-right pink fill.
///
/// The groove is never glass - just a 5px line. The ONLY glass is the
/// thumb (the package clear-pill lens, [LiquidGlassSlider.defaultStyle]):
/// it fades/scales in on touch-down and is gone at rest, so the idle
/// bar is line + fill only.
///
/// One axis only: horizontal drags seek, vertical drags stay with
/// dismiss (reported through [onDismiss]) - the arena picks one
/// winner, so the seek never fights a dismiss zone.
///
/// Pure control: no providers, no engine. The caller feeds the live
/// [positionMs] and commits through [onSeek] (guarded seek entry),
/// so the widget pumps clean in tests.
class ArchSeekBar extends StatefulWidget {
  /// Engine position in ms while idle. Ignored mid-drag: the drag
  /// owns the readout until release, then the engine takes over.
  final double positionMs;

  /// Track length in ms (> 0; caller clamps zero-length to 1).
  final double totalMs;

  /// Committed seek target in ms: tap landing or drag release.
  final ValueChanged<double> onSeek;

  /// Vertical drag past the dismiss threshold - the caller closes.
  final VoidCallback onDismiss;

  const ArchSeekBar({
    super.key,
    required this.positionMs,
    required this.totalMs,
    required this.onSeek,
    required this.onDismiss,
  });

  @override
  State<ArchSeekBar> createState() => _ArchSeekBarState();
}

class _ArchSeekBarState extends State<ArchSeekBar> {
  /// Drag preview in ms. Non-null while a horizontal drag owns the
  /// readout; the engine position resumes on release.
  double? _dragMs;

  /// Vertical travel of the in-flight dismiss drag.
  double _dy = 0;

  /// Deadband: sub-0.2% tremble never moves the fill.
  static const _deadband = 0.002;

  /// Dismiss thresholds, shared with the top-bar `_DismissDrag` zone:
  /// fast fling or a committed 90px pull.
  static const _dismissVelocity = 400.0;
  static const _dismissDistance = 90.0;

  static const _thumb = Size(40, 26);

  bool get _dragging => _dragMs != null;

  double _msAt(double x, double width) =>
      (x / width * widget.totalMs).clamp(0.0, widget.totalMs);

  @override
  Widget build(BuildContext context) {
    final max = widget.totalMs > 0 ? widget.totalMs : 1.0;
    final shownMs =
        (_dragMs ?? widget.positionMs.clamp(0.0, max)).clamp(0.0, max);
    final remainingMs = (max - shownMs).clamp(0.0, max);
    final frac = (shownMs / max).clamp(0.0, 1.0);
    final reduced = Motion.reduced(context);
    final anim = reduced ? Duration.zero : Motion.stateChange;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
      child: Column(
        children: [
          // Seek preview: the dragged time reads large above the bar,
          // then settles back. Nothing while resting.
          AnimatedOpacity(
            duration: anim,
            opacity: _dragging ? 1 : 0,
            child: SizedBox(
              height: _dragging ? 34 : 0,
              child: _dragging
                  ? Center(
                      child: Text(
                        fmtDuration(
                          Duration(milliseconds: shownMs.toInt()),
                        ),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              // Thumb center rides the fill edge, clamped so the pill
              // never leaves the line's ends.
              final cx = (frac * w).clamp(
                _thumb.width / 2,
                w - _thumb.width / 2,
              );
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Tap jumps straight there - the explicit half of
                // left-to-right seeking.
                onTapUp: (d) => widget.onSeek(
                  _msAt(d.localPosition.dx, w),
                ),
                onHorizontalDragStart: (d) {
                  setState(() {
                    _dragMs = _msAt(d.localPosition.dx, w);
                    _dy = 0;
                  });
                },
                onHorizontalDragUpdate: (d) {
                  final anchor = _dragMs;
                  if (anchor == null) return;
                  final ms = _msAt(d.localPosition.dx, w);
                  if ((ms - anchor).abs() < max * _deadband) return;
                  setState(() => _dragMs = ms);
                },
                onHorizontalDragEnd: (_) {
                  final v = _dragMs;
                  setState(() {
                    _dragMs = null;
                    _dy = 0;
                  });
                  if (v == null) return;
                  widget.onSeek(v);
                },
                onHorizontalDragCancel: () => setState(() {
                  _dragMs = null;
                  _dy = 0;
                }),
                // Vertical stays with dismiss: same thresholds as the
                // top-bar zone, so the whole column answers one way.
                // The arena picks horizontal OR vertical - never both.
                onVerticalDragUpdate: (d) => _dy += d.delta.dy,
                onVerticalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  final dy = _dy;
                  _dy = 0;
                  if (v > _dismissVelocity || dy > _dismissDistance) {
                    widget.onDismiss();
                  }
                },
                onVerticalDragCancel: () => _dy = 0,
                child: Container(
                  key: const Key('arch_seek_track'),
                  // Fat touch target, thin visual: sensitivity lives
                  // in the gesture, not in a fat bar.
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  color: Colors.transparent,
                  child: SizedBox(
                    // Room for the thumb pop - it paints above the
                    // line, never clipped mid-drag.
                    height: _thumb.height + 8,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Plain 5px track: pale line, pink fill strictly
                        // left-to-right from the track start.
                        Container(
                          width: double.infinity,
                          height: 5,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2.5),
                            color: ink.withValues(alpha: 0.12),
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: frac,
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(2.5),
                                  color: archPink,
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Glass thumb ONLY while dragging: clear pill
                        // lens, fading/scaling in on touch-down and
                        // out on release. Springs pop it (Motion.settle);
                        // reduced-motion cuts the fade to an appear.
                        Positioned(
                          left: cx - _thumb.width / 2,
                          child: IgnorePointer(
                            child: AnimatedOpacity(
                              key: const Key('arch_seek_thumb_fade'),
                              duration: anim,
                              opacity: _dragging ? 1 : 0,
                              child: AnimatedScale(
                                key: const Key('arch_seek_thumb_scale'),
                                scale: _dragging ? 1.0 : 0.5,
                                duration: anim,
                                curve: Motion.settle,
                                child: LiquidGlassLens(
                                  style:
                                      LiquidGlassSlider.defaultStyle,
                                  child: SizedBox(
                                    width: _thumb.width,
                                    height: _thumb.height,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                fmtDuration(Duration(milliseconds: shownMs.toInt())),
                style: const TextStyle(color: inkDim, fontSize: 12),
              ),
              Text(
                '-${fmtDuration(Duration(milliseconds: remainingMs.toInt()))}',
                style: const TextStyle(color: inkDim, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
