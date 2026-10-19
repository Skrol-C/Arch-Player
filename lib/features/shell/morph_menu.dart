import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../player/track_menu.dart' show MenuAction, menuAnchor;

/// Morph context menu: the V2 glass experiment.
///
/// PARKED, not wired: the artists page uses the house showTrackMenu
/// again. Kept intact (and analyzer-clean) so the recipe can be
/// switched back on by importing this file and calling showMorphMenu.
/// Same contract as showTrackMenu (anchor rect in, tapped value out),
/// but the menu *grows* out of its anchor like water instead of
/// appearing — elastic overshoot settle, radial specular sweep,
/// saturated optical rim. Dismissal sucks back in fast. Reduced
/// motion gets a plain fade: no bulge, no travel.
Future<String?> showMorphMenu({
  required BuildContext context,
  Rect? anchor,
  required List<MenuAction> items,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  FocusManager.instance.primaryFocus?.unfocus();
  final target = anchor ?? menuAnchor(context);
  ArchLog.i(
    'nav',
    'morph menu open anchor=${target == null ? 'none' : '${target.width.toStringAsFixed(0)}x${target.height.toStringAsFixed(0)}@${target.left.toStringAsFixed(0)},${target.top.toStringAsFixed(0)}'}',
  );
  return navigator.push<String>(
    PageRouteBuilder<String>(
      barrierColor: Colors.black.withValues(alpha: 0.12),
      barrierDismissible: true,
      opaque: false,
      transitionDuration: Motion.reduced(context)
          ? Duration.zero
          : const Duration(milliseconds: 550),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, animation, _) {
        final media = MediaQuery.of(context);
        return AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final t = animation.value;
            final reduced = Motion.reduced(context);
            // Spring out of the anchor: full elastic overshoot on the
            // way in, quick linear-ish suck-back on dismiss.
            final grow = reduced
                ? 1.0
                : Curves.elasticOut.transform((t / 0.85).clamp(0.0, 1.0));
            final show = reduced
                ? t
                : Curves.easeOutCubic.transform((t / 0.35).clamp(0.0, 1.0));
            final below =
                target == null ||
                target.bottom + 320 <= media.size.height - media.padding.bottom;
            return FocusScope(
              canRequestFocus: false,
              skipTraversal: true,
              child: CustomSingleChildLayout(
                delegate: _MorphLayout(
                  anchor: target,
                  padding: media.padding,
                  below: below,
                ),
                child: Transform.scale(
                  scale: reduced ? 1.0 : (0.35 + 0.65 * grow.clamp(0.0, 1.15)),
                  alignment: below
                      ? Alignment.topCenter
                      : Alignment.bottomCenter,
                  child: Opacity(
                    opacity: show.clamp(0.0, 1.0),
                    child: IgnorePointer(
                      ignoring:
                          t < 0.6 &&
                          animation.status != AnimationStatus.reverse,
                      child: LiquidGlassLens(
                        style: ArchGlass.menuV2(),
                        child: _MorphRows(
                          items: items,
                          stagger: reduced ? 1.0 : (t / 0.5).clamp(0.0, 1.0),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class _MorphLayout extends SingleChildLayoutDelegate {
  final Rect? anchor;
  final EdgeInsets padding;
  final bool below;
  static const _margin = 12.0;
  static const _width = 280.0;

  const _MorphLayout({
    required this.anchor,
    required this.padding,
    required this.below,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(
      _width,
      math.max(0.0, constraints.maxWidth - padding.horizontal - _margin * 2),
    );
    final height = math.max(
      0.0,
      constraints.maxHeight - padding.vertical - _margin * 2,
    );
    return BoxConstraints(minWidth: width, maxWidth: width, maxHeight: height);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = padding.left + _margin;
    final right = math.max(
      left,
      size.width - padding.right - _margin - childSize.width,
    );
    if (anchor == null) {
      return Offset((size.width - childSize.width) / 2, size.height * 0.3);
    }
    final x = (anchor!.center.dx - childSize.width / 2).clamp(left, right);
    final y = below
        ? anchor!.bottom + 8
        : math.max(padding.top + _margin, anchor!.top - childSize.height - 8);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MorphLayout old) =>
      anchor != old.anchor || padding != old.padding || below != old.below;
}

class _MorphRows extends StatelessWidget {
  final List<MenuAction> items;
  final double stagger;
  const _MorphRows({required this.items, required this.stagger});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++)
            _MorphRow(
              action: items[i],
              progress: ((stagger * items.length - i).clamp(0.0, 1.0)),
              last: i == items.length - 1,
            ),
        ],
      ),
    );
  }
}

class _MorphRow extends StatelessWidget {
  final MenuAction action;
  final double progress;
  final bool last;
  const _MorphRow({
    required this.action,
    required this.progress,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    final p = Curves.easeOutCubic.transform(progress.clamp(0.0, 1.0));
    return Opacity(
      opacity: p,
      child: Transform.translate(
        offset: Offset(0, 10 * (1 - p)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => Navigator.of(context).pop(action.value),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(action.icon, color: ink, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            action.label,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          if (action.subtitle != null)
                            Text(
                              action.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: inkDim,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (action.selected)
                      const Icon(
                        CupertinoIcons.check_mark,
                        color: archPink,
                        size: 18,
                      ),
                  ],
                ),
              ),
            ),
            if (!last)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Divider(height: 1, color: Color(0x140B0B0D)),
              ),
          ],
        ),
      ),
    );
  }
}
