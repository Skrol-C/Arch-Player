import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../library/song_row.dart';
import '../needle/queue_store.dart';
import '../player/mini_player.dart';
import '../player/morph_icon.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';

enum Destination { home, library, search, needle }

final destinationProvider = StateProvider<Destination>(
  (ref) => Destination.home,
);

/// Scroll-collapse state: true = pill split into lobes with the compact
/// mini between. Collapses on scroll-down, expands on tap, scroll-up,
/// or destination change. Player-open hides everything regardless.
final pillCollapsedProvider = StateProvider<bool>((ref) => false);

/// Where the library search bar sits. Three stops, not two:
/// `hidden` deep in a list, `peek` as a slim row after a downward
/// swipe mid-list, `open` as the full field at the top of a page.
/// The last one is the moment: arriving at the top is what expands
/// the row into the field, so the top never reads as "it was always
/// there".
enum SearchStage { hidden, peek, open }

final searchStageProvider = StateProvider<SearchStage>(
  (ref) => SearchStage.open,
);

const _labels = ['Home', 'Library', 'Search', 'Needle'];
const _icons = [
  Icons.home_rounded,
  Icons.library_music_rounded,
  Icons.search_rounded,
  Icons.download_rounded,
];

/// Forwards vertical scroll intent to the collapse driver. Wrap every
/// scroll root that shares the dock (shell body + pushed routes).
///
/// Also drives the library search stage. That one is position-honest
/// rather than page-forced: a page at its top shows the full field, a
/// page scrolled down keeps it retracted, a downward swipe mid-list
/// brings back the slim peek row, and returning to the top is what
/// expands it. `ScrollMetricsNotification` is the hook that catches a
/// page landing already-at-top (or a list resizing), which the
/// user-scroll stream alone never reports.
class DockScrollReporter extends ConsumerStatefulWidget {
  final Widget child;
  const DockScrollReporter({super.key, required this.child});

  @override
  ConsumerState<DockScrollReporter> createState() =>
      _DockScrollReporterState();
}

class _DockScrollReporterState extends ConsumerState<DockScrollReporter> {
  /// Sustained-travel accumulator: flips only fire after enough
  /// same-direction travel, so scroll wobble never restarts the
  /// 380ms glass choreography mid-flight. Reset on direction change.
  static const _upThreshold = 48.0;
  static const _downThreshold = 80.0;
  double _accum = 0;
  ScrollDirection? _lastDir;

  /// Travel lock: while the pill morph is running, further flips
  /// are swallowed instead of restarting the animation + the page
  /// relayout that rides with it.
  DateTime _lastFlip = DateTime.fromMillisecondsSinceEpoch(0);
  static const _lockMs = 380;

  bool _lockOpen() {
    return DateTime.now().difference(_lastFlip).inMilliseconds < _lockMs;
  }

  void _stage(WidgetRef ref, SearchStage next) {
    final s = ref.read(searchStageProvider.notifier);
    if (s.state == next) return;
    ArchLog.i('nav', 'search ${s.state.name} -> ${next.name}');
    s.state = next;
    _lastFlip = DateTime.now();
  }

  void _setCollapsed(WidgetRef ref, bool collapsed, String why) {
    final c = ref.read(pillCollapsedProvider.notifier);
    if (c.state == collapsed) return;
    ArchLog.i('nav', 'pill $why');
    c.state = collapsed;
    _lastFlip = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) {
        if (n.metrics.axis != Axis.vertical) return false;
        if (n.metrics.pixels <= _searchAtTop) {
          _stage(ref, SearchStage.open);
        }
        return false;
      },
      child: NotificationListener<UserScrollNotification>(
        onNotification: (n) {
          if (n.metrics.axis != Axis.vertical) return false;
          final dir = n.direction;
          if (dir == ScrollDirection.idle) return false;
          if (dir != _lastDir) {
            _lastDir = dir;
            _accum = 0;
          }
          _accum += (n.metrics.pixels - (_lastPx ?? n.metrics.pixels)).abs();
          _lastPx = n.metrics.pixels;
          final locked = _lockOpen();
          if (dir == ScrollDirection.forward &&
              n.metrics.pixels > _downThreshold &&
              _accum >= _downThreshold &&
              !locked) {
            _setCollapsed(ref, true, 'collapse (scroll down)');
          } else if (dir == ScrollDirection.reverse &&
              _accum >= _upThreshold &&
              !locked) {
            _setCollapsed(ref, false, 'expand (scroll up)');
          }
          // Search stage, same stream so it can never desync from the
          // scroll it belongs to. At the top = full field; diving in =
          // gone; a downward swipe mid-list = slim peek row.
          final px = n.metrics.pixels;
          if (px <= _searchAtTop) {
            _stage(ref, SearchStage.open);
          } else if (dir == ScrollDirection.reverse &&
              px > _downThreshold &&
              _accum >= _upThreshold &&
              !locked) {
            _stage(ref, SearchStage.hidden);
          } else if (dir == ScrollDirection.forward &&
              _accum >= _downThreshold &&
              !locked) {
            if (ref.read(searchStageProvider) == SearchStage.hidden) {
              _stage(ref, SearchStage.peek);
            }
          }
          return false;
        },
        child: widget.child,
      ),
    );
  }

  double? _lastPx;
}

/// Search sits at the top of a page within this many pixels.
const double _searchAtTop = 40;

/// Gravity fall for the resting mini on collapse: accelerates down for
/// the first stretch, dissolves BEFORE touching the pill (two stacked
/// lenses read gray), gone well before the landing. The compact mini
/// takes over between the lobes; on expand this runs in reverse.
({double y, double opacity}) _miniFall(double t) {
  if (t <= 0) return (y: 0.0, opacity: 1.0);
  if (t >= 1) return (y: 56.0, opacity: 0.0);
  double y;
  if (t < 0.7) {
    final k = t / 0.7;
    y = 56 * k * k;
  } else {
    final k = (t - 0.7) / 0.3;
    y = 56 - math.sin(k * math.pi) * 8 * (1 - k);
  }
  // Contact with the pill starts at y=12 (the resting gap); the fade
  // is done by y~11 (t=0.32) so glass never stacks on glass.
  final opacity = 1 - ((t - 0.10) / 0.22).clamp(0.0, 1.0);
  return (y: y, opacity: opacity);
}

/// The bottom unit, everywhere: full mini + full pill at rest, lobes +
/// compact mini split on scroll. One animation driver - the pieces move
/// as one body, never on separate timings. Mounts in Shell and on every
/// pushed route (artist, album, gallery): no routeless screens.
class NowPlayingDock extends ConsumerWidget {
  const NowPlayingDock({super.key});

  static const double pillWidth = 340;
  static const double miniWidth = 280;

  /// The mini yields like the pill: full-bleed minus margins on
  /// narrow windows instead of clipping past the screen edge.
  static double miniWidthOf(BuildContext context) {
    return math
        .min(
          miniWidth,
          math.max(0.0, MediaQuery.sizeOf(context).width - 32),
        )
        .toDouble();
  }

  /// Adaptive measured width: full-bleed minus margins, capped for
  /// tablets. No floor: split-screen and largest-display-size windows
  /// can run narrower than any tab-legible minimum, and a squished
  /// pill beats a clipped one. Labels shrink a point under large
  /// text instead of pushing the pill offscreen.
  static const double _pillMaxWidth = 340;
  static double pillWidthOf(BuildContext context) {
    return (MediaQuery.sizeOf(context).width - 32).clamp(0.0, _pillMaxWidth);
  }

  static double tabLabelSize(BuildContext context) {
    return MediaQuery.textScalerOf(context).scale(1.0) > 1.15 ? 9 : 10;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerOpen = ref.watch(playerOpenProvider);
    if (playerOpen) return const SizedBox.shrink();
    final miniVisible = ref.watch(miniVisibleProvider);
    final collapsed = ref.watch(pillCollapsedProvider);
    final bottom = MediaQuery.paddingOf(context).bottom + 12;
    // Single driver t: 0 = full unit, 1 = split. Everything below reads
    // t and nothing else - locked choreography, no drift between parts.
    // 380ms spring travel: the parting must be SEEN, not inferred.
    // NOTE: never wrap this in Center - Positioned gives unbounded
    // height and Center cannot lay out in it (dead taps app-wide).
    // Batch REMOVED (was here): mini + pill + lobes shared one backdrop
    // read, and the shared capture resized under traveling members -
    // the gray shift on collapse/expand. Each lens reads its own
    // backdrop now; if the Honor chugs, the batch goes back and the
    // travel gets a different cure.
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottom,
      child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: collapsed ? 1.0 : 0.0),
          duration: Motion.reduced(context)
              ? Duration.zero
              : const Duration(milliseconds: 380),
          curve: Motion.arrival,
          builder: (context, t, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (miniVisible)
                  // Invisible layers must not eat taps: opacity alone
                  // still hit-tests. Guards flip at the halfway mark.
                  IgnorePointer(
                    ignoring: t > 0.5,
                    child: Builder(
                      builder: (context) {
                        final fall = _miniFall(t);
                        return Opacity(
                          opacity: fall.opacity,
                          child: Transform.translate(
                            offset: Offset(0, fall.y),
                            child: SizedBox(
                              width: NowPlayingDock.miniWidthOf(context),
                              // The fall curve IS the entrance/exit: no
                              // FocalEntrance here, its 650ms materialize
                              // replayed on every expand and read gray.
                              // Track changes reuse the mounted bar
                              // silently (keyed art inside MiniPlayer).
                              child: t > 0.9
                                  ? const SizedBox.shrink()
                                  : const MiniPlayer(),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                if (miniVisible) SizedBox(height: (1 - t) * 12),
                // Fixed-height slot: the TabBar sizes itself and demands
                // bounded height, but this Column lives in a bottom-only
                // Positioned (unbounded). Without the bound the TabBar's
                // internals throw infinite-height on every frame. 76 fits
                // its natural height with room for text scaling.
                SizedBox(
                  width: NowPlayingDock.pillWidthOf(context),
                  height: 76,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      IgnorePointer(
                        ignoring: t > 0.5,
                        child: Opacity(
                          opacity: 1 - t,
                          child: Transform.scale(
                            scale: 1 - 0.15 * t,
                            child: t > 0.9
                                ? const SizedBox.shrink()
                                : const _FullPill(),
                          ),
                        ),
                      ),
                      IgnorePointer(
                        ignoring: t <= 0.5,
                        child: _SplitTravel(t: t, miniVisible: miniVisible),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
    );
  }

  /// Destination tap from anywhere (shell or pushed route): switch,
  /// expand, and pop back to the root when under a route.
  static void _go(WidgetRef ref, BuildContext context, Destination? d) {
    if (d != null) {
      ArchLog.i('nav', 'pill -> $d');
      ref.read(destinationProvider.notifier).state = d;
      if (d == Destination.needle) {
        // Visiting clears the landing glow; pending counts live on.
        ref.read(needleGlowProvider.notifier).state = false;
      }
    }
    ref.read(pillCollapsedProvider.notifier).state = false;
    final nav = Navigator.of(context);
    if (d != null && nav.canPop()) nav.popUntil((r) => r.isFirst);
  }
}

/// The compact 280 pill: tighter than V1, icons first. The resting
/// state of the dock. Destination changes land with a squash-stretch
/// pulse — the traveling indicator's exclamation point.
class _FullPill extends ConsumerStatefulWidget {
  const _FullPill();

  @override
  ConsumerState<_FullPill> createState() => _FullPillState();
}

class _FullPillState extends ConsumerState<_FullPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  int? _lastDest;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _pulse(Widget child) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, kid) {
        final k = math.sin((_c.value * math.pi).clamp(0.0, 1.0));
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(1 + 0.045 * k, 1 - 0.045 * k, 1),
          child: kid,
        );
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dest = ref.watch(destinationProvider);
    if (_lastDest != null && _lastDest != dest.index) {
      _lastDest = dest.index;
      if (!Motion.reduced(context)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _c.forward(from: 0);
        });
      }
    } else {
      _lastDest ??= dest.index;
    }
    final pending = ref
        .watch(downloadQueueProvider)
        .where(
          (j) => j.state == QueueState.queued || j.state == QueueState.active,
        )
        .length;
    final glow = ref.watch(needleGlowProvider);
    final bar = LiquidGlassTabBar.withImpeller(
      items: [
        for (var i = 0; i < _labels.length; i++)
          LiquidGlassTabBarItem(icon: _icons[i], label: _labels[i]),
      ],
      selectedIndex: dest.index,
      onChanged: (i) => NowPlayingDock._go(ref, context, Destination.values[i]),
      width: NowPlayingDock.pillWidthOf(context),
      margin: EdgeInsets.zero,
      itemStyle: LiquidGlassTabItemStyle(
        selectedColor: archPink,
        unselectedColor: const Color(0x990B0B0D),
        iconSize: 22,
        underGlassIconSize: 28,
        labelFontSize: NowPlayingDock.tabLabelSize(context),
      ),
      pillStyle: const LiquidGlassTabPillStyle(
        // The physics pill: squash-and-stretch travel, draggable,
        // icon reveal. `animated: true` alone is only a slide -
        // the mode is what buys the morphing glass.
        mode: LiquidGlassPillMode.impellerOnly,
        animated: true,
        animationDuration: Duration(milliseconds: 400),
      ),
      style: LiquidGlassTabBar.defaultStyle.copyWith(
        appearance: ArchGlass.frostAppearance,
        adaptivity: ArchGlass.adaptive,
      ),
    );
    // Queue badge + landing glow: above the Needle tab
    // (index 3 of 4), never the pill corner. Fractional offset
    // survives width changes.
    if (pending == 0 && !glow) return _pulse(bar);
    final pillW = NowPlayingDock.pillWidthOf(context);
    return _pulse(
      Stack(
        clipBehavior: Clip.none,
        children: [
          bar,
          Positioned(
            left: pillW * 0.625,
            top: -8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: archPink,
                borderRadius: BorderRadius.circular(12),
                boxShadow: glow
                    ? [
                        BoxShadow(
                          color: archPink.withValues(alpha: 0.55),
                          blurRadius: 10,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: Text(
                pending > 0 ? '$pending' : 'new',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Collapsed state with real travel: both lobes start stacked at
/// center and part outward as t rises; the compact mini scales up
/// between them. Same single driver - one body, never separate
/// timings. Reduced-motion jumps t, so all travel becomes a cut.
///
/// Static children (lobes, compact mini) are cached in state and
/// rebuilt only when destination or mini visibility change - never
/// on animation ticks. Ticks only recompute the cheap wrappers
/// (opacity/offset/scale), so the glass lenses below never reconcile
/// mid-travel. Same hoisting discipline as the player stage.
class _SplitTravel extends ConsumerStatefulWidget {
  final double t;
  final bool miniVisible;

  const _SplitTravel({required this.t, required this.miniVisible});

  /// Half the split width: lobes rest 108px out from center each side.
  static const _part = 108.0;

  @override
  ConsumerState<_SplitTravel> createState() => _SplitTravelState();
}

class _SplitTravelState extends ConsumerState<_SplitTravel> {
  int? _destIndex;
  bool? _miniVisible;
  Widget? _left;
  Widget? _middle;
  Widget? _right;

  @override
  Widget build(BuildContext context) {
    final dest = ref.watch(destinationProvider);
    // Identical instances across ticks: the element tree below skips
    // updates entirely until destination or visibility actually change.
    // The expand tap reads the provider live so the cached closure
    // never goes stale either.
    if (_left == null ||
        _destIndex != dest.index ||
        _miniVisible != widget.miniVisible) {
      _left = _Lobe(
        icon: _icons[dest.index],
        color: archPink,
        tooltip: _labels[dest.index],
        onTap: () => ref.read(pillCollapsedProvider.notifier).state = false,
      );
      _middle = widget.miniVisible ? const _CompactMini() : null;
      _right = _Lobe(
        icon: CupertinoIcons.search,
        color: dest == Destination.search ? archPink : ink,
        tooltip: 'Search',
        onTap: () => NowPlayingDock._go(ref, context, Destination.search),
      );
      _destIndex = dest.index;
      _miniVisible = widget.miniVisible;
    }
    final t = widget.t;
    if (t < 0.02) return const SizedBox.shrink();
    // Full pill width: with the mini the cluster stays centered (same
    // part-travel as ever); without it the lobes take opposite ends
    // and fade-scale in place instead of crossing the whole pill.
    final pop = Curves.easeOutBack.transform(t.clamp(0.0, 1.0));
    return Opacity(
      opacity: t,
      child: SizedBox(
        width: NowPlayingDock.pillWidthOf(context),
        child: _middle == null
            ? Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Transform.scale(scale: 0.8 + 0.2 * t, child: _left!),
                  Transform.scale(scale: 0.8 + 0.2 * t, child: _right!),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Transform.translate(
                    offset: Offset((1 - t) * _SplitTravel._part, 0),
                    child: _left!,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Transform.scale(
                      scale: 0.75 + 0.25 * pop,
                      child: _middle!,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Transform.translate(
                    offset: Offset(-(1 - t) * _SplitTravel._part, 0),
                    child: _right!,
                  ),
                ],
              ),
      ),
    );
  }
}

class _Lobe extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String? tooltip;

  const _Lobe({
    required this.icon,
    required this.color,
    required this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return LiquidGlassLens(
      style: ArchGlass.circle(radius: 26),
      child: SizedBox(
        width: 52,
        height: 52,
        child: IconButton(
          iconSize: 24,
          color: color,
          tooltip: tooltip,
          onPressed: onTap,
          icon: Icon(icon),
        ),
      ),
    );
  }
}

/// Compact middle of the split pill: art + scrolling title/artist +
/// pause. Flexible width — the split row grants it whatever the lobes
/// leave, so it adapts to narrow screens instead of overflowing them.
class _CompactMini extends ConsumerWidget {
  const _CompactMini();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.watch(currentSongProvider).value;
    final playing = ref.watch(playingProvider).value ?? false;
    if (song == null) return const SizedBox.shrink();
    final handler = ref.read(audioHandlerProvider);
    return LiquidGlassLens(
      style: ArchGlass.capsule(radius: 26),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => openPlayer(ref, context),
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              AnimatedSwitcher(
                duration: Motion.stateChange,
                child: SizedBox(
                  key: ValueKey(song.albumId),
                  width: 38,
                  height: 38,
                  child: song.albumId > 0 || song.path.isNotEmpty
                      ? FileArtImage(
                          path: song.path,
                          albumId: song.albumId,
                          size: 38,
                          radius: 10,
                        )
                      : Container(
                          decoration: BoxDecoration(
                            color: paperRaised,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            CupertinoIcons.music_note,
                            color: inkDim,
                            size: 20,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarqueeText(
                      text: song.title,
                      style: TextStyle(
                        color: playing ? archPink : ink,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: inkDim, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 40,
                height: 40,
                child: IconButton(
                  iconSize: 24,
                  color: ink,
                  onPressed: () => playGuarded(
                    context,
                    () => playing ? handler.pause() : handler.play(),
                  ),
                  icon: MorphIcon(
                    iconKey: playing,
                    child: Icon(
                      playing
                          ? CupertinoIcons.pause_fill
                          : CupertinoIcons.play_fill,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
