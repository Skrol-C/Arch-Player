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
/// but the menu grows out of its button through native LiquidGlassMorph.
///
/// Edge origin, via the package's own tool: the morph fills the whole
/// screen and its [LiquidGlassMorph.alignment] is recovered with
/// [LiquidGlassMorph.alignmentFor] from the rect we actually want —
/// a 48 px seed centred on the button pixel while held, the menu rect
/// after. The birth point (`anchor.withinRect(from)`) sits on the
/// menu's EDGE nearest the button — top edge when the menu opens
/// below, bottom edge when it opens above, at the button's horizontal
/// station — and growth flows outward from there instead of leaping
/// middle-outward. The same edge anchors the drain: shrinking, the old
/// blob's size collapses first around that edge point while its anchor
/// lags (stretch + followDelay), so the menu deflates TOWARD the
/// button and stays tethered through the whole drain instead of
/// shrinking into a floating detached rectangle. See
/// `LiquidGlassMorphMotion.anchor` and `LiquidGlassMorph.alignmentFor`
/// in liquid_glass_easy 4.3.4.
///
/// Timing: 0.40 s spring (2π/√246.7), zeta 0.70 for the ripple, with
/// a slight lead overshoot (leadZeta = zeta − leadBounce = 0.60) for
/// the liquid snap-back.
///
/// Motion is deliberately NOT anchoredPop: per liquid_glass_easy 4.3.4
/// (liquid_glass_morph_motion.dart, anchoredPop docs) anchor-null means
/// "the anchor barely travels, so there is no neck". A waist needs a
/// travelling anchor, so this uses the explicit edge anchor with high
/// stretch: the new blob is born small inside the seed, its anchor leaps
/// for the menu edge while its size lags (followDelay), and the seed
/// drains to a speck (sourceFollows: false) instead of merging — the two
/// blobs stay distinct mid-flight and the blender's smooth union reads
/// as a neck. neckRamp 12 brings the fillet in early.
///
/// Content rides the package clock (LiquidGlassMorphAdvanced content
/// params, same file): it materialises between contentInStart..contentInEnd
/// of the morph duration, scaling newScaleFrom→1 about the anchor with
/// contentFollow 1 so it travels inside the growing blob instead of
/// sitting pinned at full size under small glass.
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
          : const Duration(milliseconds: 600),
      reverseTransitionDuration: _reverseDuration(context),
      pageBuilder: (context, animation, _) => _MorphPage(
        animation: animation,
        anchor: target,
        items: items,
      ),
    ),
  );
}

/// Reverse clock: the 0.40 s drain settles in ~0.35 s, plus margin.
Duration _reverseDuration(BuildContext context) => Motion.reduced(context)
    ? const Duration(milliseconds: 180)
    : const Duration(milliseconds: 450);

/// Liquid morph: born small on the button, anchor leaps for the menu
/// EDGE nearest the button while size lags (stretch + followDelay),
/// seed drains to a speck so the mid-flight union keeps a waist.
/// Content materialises across the full morph (contentInStart..contentInEnd)
/// from seed scale, riding the growing blob (contentFollow 1).
/// The edge anchor also governs the drain: same value both directions,
/// so dismiss deflates toward the button edge instead of detaching.
LiquidGlassMorphMotion _morphMotion(Alignment edge) => LiquidGlassMorphMotion(
  stiffness: 246.7,
  damping: 22.0,
  stretch: 0.9,
  anchor: edge,
  advanced: const LiquidGlassMorphAdvanced(
    leadBounce: 0.10,
    followDelay: 0.09,
    seedScale: 0.55,
    linger: 0.05,
    drainSpeed: 1.5,
    drainInward: 0.35,
    sourceFollows: false,
    neckRamp: 12,
    contentOutEnd: 0.40,
    contentInStart: 0.12,
    contentInEnd: 1.0,
    newScaleFrom: 0.55,
    oldScaleTo: 0.92,
    contentBlur: 8,
    contentFollow: 1.0,
    contentSlide: 0,
    thickenBlur: 0.35,
    thickenRefraction: 0.30,
  ),
);

/// The neck's hinge: the menu edge nearest the button, at the button's
/// horizontal station — so the union anchors at the edge, not the
/// middle. Menu below the seed grows around its top edge, above around
/// its bottom. Null anchor (tall callers, centred menu) has no button:
/// fall back to the middle.
Alignment _edgeAnchor(Rect seed, Rect menu) {
  final x = menu.width <= 0
      ? 0.0
      : (((seed.center.dx - menu.left) / menu.width) * 2 - 1)
            .clamp(-1.0, 1.0)
            .toDouble();
  final below = menu.center.dy >= seed.center.dy;
  return Alignment(x, below ? -1.0 : 1.0);
}

const _menuWidth = 280.0;
const _seedSize = 48.0;
const _gap = 8.0;
const _margin = 12.0;

double _clampV(double v, double lo, double hi) =>
    hi <= lo ? lo : v.clamp(lo, hi);

/// Estimated menu height from the rows we render: InkWell vertical
/// padding 24 + label ~22, subtitle adds ~16, 1 px dividers, 16 outer.
/// Only used to pick above/below and the hinge rect; the morph itself
/// measures the real height and the hinge tracks it exactly.
double _estimateMenuHeight(List<MenuAction> items) {
  var h = 16.0;
  for (var i = 0; i < items.length; i++) {
    h += 46.0 + (items[i].subtitle != null ? 16.0 : 0.0);
    if (i < items.length - 1) h += 1.0;
  }
  return h;
}

/// Seed rect: a 48 px dot centred on the button pixel, clamped inside
/// the safe area. alignmentFor of this rect puts the birth point AT
/// the tap while the seed is held.
Rect _seedRect(Rect? anchor, Size field, EdgeInsets padding) {
  final c = anchor?.center ?? Offset(field.width / 2, field.height / 2);
  final maxX = math.max(
    padding.left + _margin,
    field.width - padding.right - _margin - _seedSize,
  );
  final maxY = math.max(
    padding.top + _margin,
    field.height - padding.bottom - _margin - _seedSize,
  );
  return Rect.fromLTWH(
    _clampV(c.dx - _seedSize / 2, padding.left + _margin, maxX),
    _clampV(c.dy - _seedSize / 2, padding.top + _margin, maxY),
    _seedSize,
    _seedSize,
  );
}

/// Menu rect: fixed 280 wide, centred on the button and clamped
/// on-screen, opening below the button when it fits and above when
/// not. alignmentFor of this rect is the hinge the morph grows around.
Rect _menuRect(Rect? anchor, double estH, Size field, EdgeInsets padding) {
  final minX = padding.left + _margin;
  final maxX = math.max(
    minX,
    field.width - padding.right - _margin - _menuWidth,
  );
  final minY = padding.top + _margin;
  final cx = anchor?.center.dx ?? field.width / 2;
  final x = _clampV(cx - _menuWidth / 2, minX, maxX);
  final bottomEdge = field.height - padding.bottom - _margin;
  double y;
  if (anchor == null) {
    y = (field.height - estH) / 2;
  } else if (anchor.bottom + _gap + estH <= bottomEdge) {
    y = anchor.bottom + _gap;
  } else {
    y = anchor.top - _gap - estH;
  }
  return Rect.fromLTWH(x, _clampV(y, minY, math.max(minY, bottomEdge - estH)), _menuWidth, estH);
}

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
  /// Seed hold: the glass dot sits on the button pixel this long before
  /// expansion, so the eye catches the origin.
  static const _seedHold = Duration(milliseconds: 80);
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
    final field = media.size;
    final fieldRect = Offset.zero & field;
    final estH = _estimateMenuHeight(widget.items);
    // The two rects the morph hinges on: seed exactly on the button,
    // menu adjacent to it. alignmentFor recovers each placement, and
    // the edge anchor pins the neck to the menu's button-side edge —
    // never the menu's middle, never a neighbouring offset.
    final seedRect = _seedRect(widget.anchor, field, media.padding);
    final menuRect = _menuRect(widget.anchor, estH, field, media.padding);
    final aSeed = LiquidGlassMorph.alignmentFor(seedRect, fieldRect);
    final aMenu = LiquidGlassMorph.alignmentFor(menuRect, fieldRect);
    final edge = widget.anchor == null
        ? Alignment.center
        : _edgeAnchor(seedRect, menuRect);
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, _) {
        final t = widget.animation.value;
        final reduced = Motion.reduced(context);
        // The swap the morph flows: the seed dot on the button pixel,
        // the menu after the hold, the seed again on dismiss so the
        // glass drains back into the button instead of sitting static
        // under the barrier fade. Keyed children - same type without
        // keys would not read as new.
        final reverse = widget.animation.status == AnimationStatus.reverse;
        final seedShown = !reduced && _seed && !reverse;
        final open = reduced ? !reverse : (!seedShown && !reverse && t > 0.0);
        // Seed phase and the whole drain hinge on the button rect; only
        // the open menu hinges on its own rect.
        final alignment = (seedShown || reverse) ? aSeed : aMenu;
        return FocusScope(
          canRequestFocus: false,
          skipTraversal: true,
          child: SizedBox.expand(
            child: reduced
                ? Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: Align(
                      alignment: aMenu,
                      child: LiquidGlassLens(
                        style: ArchGlass.menuMorph(),
                        child: _MorphRows(items: widget.items),
                      ),
                    ),
                  )
                : IgnorePointer(
                    ignoring: seedShown || (t < 0.6 && !reverse),
                    // anchoredPop (anchor: null) grows the new blob around
                    // the widget alignment — the hinge alignmentFor put
                    // on the button — instead of fluid's center leap.
                    // See LiquidGlassMorphMotion.anchor docs.
                    child: LiquidGlassMorph(
                      width: _menuWidth,
                      alignment: alignment,
                      motion: _morphMotion(edge),
                      smoothness: 48,
                      style: ArchGlass.menuMorph(),
                      child: open
                          ? _MorphRows(
                              key: const ValueKey('menu'),
                              items: widget.items,
                            )
                          : const SizedBox(
                              key: ValueKey('seed'),
                              width: _seedSize,
                              height: _seedSize,
                            ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _MorphRows extends StatelessWidget {
  final List<MenuAction> items;
  const _MorphRows({
    super.key,
    required this.items,
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
              last: i == items.length - 1,
            ),
        ],
      ),
    );
  }
}

class _MorphRow extends StatelessWidget {
  final MenuAction action;
  final bool last;
  const _MorphRow({
    required this.action,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
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
        );
  }
}
