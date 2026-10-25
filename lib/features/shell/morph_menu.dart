import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../player/track_menu.dart' show MenuAction, menuAnchor;

/// Morph context menu: the V2 glass experiment, live.
///
/// Same contract as showTrackMenu (anchor rect in, tapped value out),
/// but the menu *grows* out of its anchor like water via native
/// LiquidGlassMorph: a glass seed-dot held at the anchor ~150ms so the
/// eye catches the origin, then the full menu on a slowed corner-held
/// spring (~0.8 s period), keyed children so the morph reads the swap.
/// Dismissal drains back into the seed over ~0.7 s. Reduced motion gets
/// a plain fade: no morph, no travel.
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
          : const Duration(milliseconds: 950),
      reverseTransitionDuration: _reverseDuration(context),
      pageBuilder: (context, animation, _) => _MorphPage(
        animation: animation,
        anchor: target,
        items: items,
      ),
    ),
  );
}

/// Reverse clock: long enough for the drain (~0.65 s on the slowed
/// spring at drainSpeed 1.5) plus a brief seed hold before the fade.
Duration _reverseDuration(BuildContext context) => Motion.reduced(context)
    ? const Duration(milliseconds: 180)
    : const Duration(milliseconds: 700);

/// anchoredPop slowed to a visible ~0.8 s period via the package's own
/// spring params (duration = 2π/√stiffness): same bounce (zeta 0.70),
/// same corner-held advanced, period 2π/√61.7 ≈ 0.80 s so the growth
/// spans ~48 frames instead of leaping in one.
final _slowPop = LiquidGlassMorphMotion.anchoredPop.copyWith(
  stiffness: 61.7,
  damping: 11.0,
);

class _MorphPage extends StatefulWidget {
  final Animation<double> animation;
  final Rect? anchor;
  final List<MenuAction> items;

  const _MorphPage({
    required this.animation,
    required this.anchor,
    required this.items,
  });

  @override
  State<_MorphPage> createState() => _MorphPageState();
}

class _MorphPageState extends State<_MorphPage> {
  /// Seed hold: the glass dot sits at the button this long before
  /// expansion, so the eye catches the origin.
  static const _seedHold = Duration(milliseconds: 150);
  bool _seed = true;
  Timer? _seedTimer;

  @override
  void initState() {
    super.initState();
    _seedTimer = Timer(_seedHold, () {
      if (mounted) setState(() => _seed = false);
    });
  }

  @override
  void dispose() {
    _seedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, _) {
        final t = widget.animation.value;
        final reduced = Motion.reduced(context);
        final anchor = widget.anchor;
        final below =
            anchor == null ||
            anchor.bottom + 320 <= media.size.height - media.padding.bottom;
        // The swap the morph flows: the seed dot held at the anchor,
        // the menu after the hold, the seed again on dismiss so the
        // glass drains instead of sitting static under the barrier
        // fade. Keyed children - same type without keys would not
        // read as new.
        final reverse = widget.animation.status == AnimationStatus.reverse;
        final seedShown = !reduced && _seed && !reverse;
        final open = reduced ? !reverse : (!seedShown && !reverse && t > 0.0);
        final alignment =
            below ? Alignment.topCenter : Alignment.bottomCenter;
        return FocusScope(
          canRequestFocus: false,
          skipTraversal: true,
          child: CustomSingleChildLayout(
            delegate: _MorphLayout(
              anchor: anchor,
              padding: media.padding,
              below: below,
              seed: seedShown,
            ),
            child: reduced
                ? Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: LiquidGlassLens(
                      style: ArchGlass.menuMorph(),
                      child: _MorphRows(items: widget.items, stagger: 1.0),
                    ),
                  )
                : IgnorePointer(
                    ignoring: seedShown || (t < 0.6 && !reverse),
                    // anchoredPop (anchor: null) grows the new blob around
                    // the held corner — widget.alignment, i.e. the menu
                    // edge nearest the tapped button — instead of fluid's
                    // center leap. See LiquidGlassMorphMotion.anchor docs.
                    child: LiquidGlassMorph(
                      alignment: alignment,
                      motion: _slowPop,
                      style: ArchGlass.menuMorph(),
                      child: open
                          ? _MorphRows(
                              key: const ValueKey('menu'),
                              items: widget.items,
                              stagger: 1.0,
                            )
                          : const SizedBox(
                              key: ValueKey('seed'),
                              width: 48,
                              height: 48,
                            ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _MorphLayout extends SingleChildLayoutDelegate {
  final Rect? anchor;
  final EdgeInsets padding;
  final bool below;
  final bool seed;
  static const _margin = 12.0;
  static const _width = 280.0;

  const _MorphLayout({
    required this.anchor,
    required this.padding,
    required this.below,
    this.seed = false,
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
    if (seed) {
      // Seed hold: the dot sits centered on the tapped button rect so
      // the origin reads before expansion. Clamped into the safe area.
      final x = (anchor!.center.dx - childSize.width / 2).clamp(left, right);
      final top = padding.top + _margin;
      final bottom = math.max(
        top,
        size.height - padding.bottom - _margin - childSize.height,
      );
      final y = (anchor!.center.dy - childSize.height / 2).clamp(top, bottom);
      return Offset(x, y);
    }
    final x = (anchor!.center.dx - childSize.width / 2).clamp(left, right);
    final y = below
        ? anchor!.bottom + 8
        : math.max(padding.top + _margin, anchor!.top - childSize.height - 8);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MorphLayout old) =>
      anchor != old.anchor ||
      padding != old.padding ||
      below != old.below ||
      seed != old.seed;
}

class _MorphRows extends StatelessWidget {
  final List<MenuAction> items;
  final double stagger;
  const _MorphRows({
    super.key,
    required this.items,
    required this.stagger,
  });

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
