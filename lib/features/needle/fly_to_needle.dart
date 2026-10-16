import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';

/// Fly-to-Needle: after a download tap confirms, the cover flies
/// from the row to the Needle pill, shrinking + fading over
/// 450ms on a spring curve. Reduced-motion skips the flight
/// entirely (state change + haptic already happened).
Future<void> flyToNeedle(
  BuildContext context, {
  required String art,
  required Rect from,
}) async {
  if (!context.mounted) return;
  if (Motion.reduced(context)) return;
  final overlay =
      Navigator.of(context, rootNavigator: true).overlay;
  if (overlay == null) return;
  final size = MediaQuery.sizeOf(context);
  final bottom = MediaQuery.paddingOf(context).bottom + 12;
  // Needle tab sits at ~62.5% of the 340 pill, bottom-docked.
  final target = Offset(
    size.width / 2 + 340 * 0.125,
    size.height - bottom - 38,
  );
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 450),
      curve: Motion.arrival,
      onEnd: () => entry.remove(),
      builder: (_, t, _) {
        final pos = Offset.lerp(from.center, target, t)!;
        final scale = 1 - 0.8 * t;
        final edge = 24 * scale;
        return Positioned(
          left: pos.dx - edge,
          top: pos.dy - edge,
          child: Opacity(
            opacity: 1 - t * t,
            child: Transform.scale(
              scale: scale,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10 * scale + 4),
                child: art.isEmpty
                    ? Container(
                        width: 48,
                        height: 48,
                        color: paperRaised,
                        child: const Icon(Icons.music_note_rounded,
                            color: inkDim),
                      )
                    : CachedNetworkImage(
                        imageUrl: art,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => Container(
                          width: 48,
                          height: 48,
                          color: paperRaised,
                          child: const Icon(
                              Icons.music_note_rounded,
                              color: inkDim),
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    ),
  );
  overlay.insert(entry);
  await Future<void>.delayed(const Duration(milliseconds: 500));
}

Rect? rowRect(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}
