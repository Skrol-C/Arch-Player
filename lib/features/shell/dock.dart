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
class DockScrollReporter extends ConsumerWidget {
  final Widget child;
  const DockScrollReporter({super.key, required this.child});

  void _stage(WidgetRef ref, SearchStage next) {
    final s = ref.read(searchStageProvider.notifier);
    if (s.state == next) return;
    ArchLog.i('nav', 'search ${s.state.name} -> ${next.name}');
    s.state = next;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          final collapsed = ref.read(pillCollapsedProvider.notifier);
          // Sustained downward intent collapses; any upward motion
          // expands. Small gate (~80px) so flings and drags both count.
          if (n.direction == ScrollDirection.forward && n.metrics.pixels > 80) {
            if (!collapsed.state) {
              ArchLog.i('nav', 'pill collapse (scroll down)');
              collapsed.state = true;
            }
          } else if (n.direction == ScrollDirection.reverse) {
            if (collapsed.state) {
              ArchLog.i('nav', 'pill expand (scroll up)');
              collapsed.state = false;
            }
          }
          // Search stage, same stream so it can never desync from the
          // scroll it belongs to. At the top = full field; diving in =
          // gone; a downward swipe mid-list = slim peek row.
          final px = n.metrics.pixels;
          if (px <= _searchAtTop) {
            _stage(ref, SearchStage.open);
          } else if (n.direction == ScrollDirection.reverse && px > 80) {
            _stage(ref, SearchStage.hidden);
          } else if (n.direction == ScrollDirection.forward) {
            if (ref.read(searchStageProvider) == SearchStage.hidden) {
              _stage(ref, SearchStage.peek);
            }
          }
          return false;
        },
        child: child,
      ),
    );
  }
}

/// Search sits at the top of a page within this many pixels.
const double _searchAtTop = 40;

/// The bottom unit, everywhere: full mini + full pill at rest, lobes +
/// compact mini split on scroll. One animation driver - the pieces move
/// as one body, never on separate timings. Mounts in Shell and on every
/// pushed route (artist, album, gallery): no routeless screens.
class NowPlayingDock extends ConsumerWidget {
  const NowPlayingDock({super.key});

  static const double pillWidth = 340;
  static const double miniWidth = 280;
  static const double compactWidth = 148;

  /// Four tabs fit the classic width; the cap still guards narrow
  /// screens with large text.
  static const double _pillMaxWidth = 340;
  static double pillWidthOf(BuildContext context) {
    return (MediaQuery.sizeOf(context).width - 32).clamp(300.0, _pillMaxWidth);
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
    // Batch: mini + pill + lobes share one backdrop read instead of
    // one each - the Honor perf win. If glass ever artifacts here,
    // delete the batch first (one line), decor stays.
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottom,
      child: LiquidGlassBatch(
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
                    child: Opacity(
                      opacity: 1 - t,
                      child: Transform.translate(
                        offset: Offset(0, -10 * t),
                        child: SizedBox(
                          width: miniWidth,
                          // Remounts replay the entrance; track changes reuse
                          // the mounted bar silently.
                          child: t > 0.9
                              ? const SizedBox.shrink()
                              : const FocalEntrance(child: MiniPlayer()),
                        ),
                      ),
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
/// state of the dock.
class _FullPill extends ConsumerWidget {
  const _FullPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dest = ref.watch(destinationProvider);
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
      itemStyle: const LiquidGlassTabItemStyle(
        selectedColor: archPink,
        unselectedColor: Color(0x990B0B0D),
        iconSize: 22,
        underGlassIconSize: 28,
        labelFontSize: 10,
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
    if (pending == 0 && !glow) return bar;
    final pillW = NowPlayingDock.pillWidthOf(context);
    return Stack(
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
        onTap: () => ref.read(pillCollapsedProvider.notifier).state = false,
      );
      _middle = widget.miniVisible ? const _CompactMini() : null;
      _right = _Lobe(
        icon: CupertinoIcons.ellipsis,
        color: inkDim,
        onTap: () => ref.read(pillCollapsedProvider.notifier).state = false,
      );
      _destIndex = dest.index;
      _miniVisible = widget.miniVisible;
    }
    final t = widget.t;
    if (t < 0.02) return const SizedBox.shrink();
    return Opacity(
      opacity: t,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.translate(
            offset: Offset((1 - t) * _SplitTravel._part, 0),
            child: _left!,
          ),
          const SizedBox(width: 8),
          if (_middle != null) ...[
            Transform.scale(scale: 0.75 + 0.25 * t, child: _middle!),
            const SizedBox(width: 8),
          ],
          Transform.translate(
            offset: Offset(-(1 - t) * _SplitTravel._part, 0),
            child: _right!,
          ),
        ],
      ),
    );
  }
}

class _Lobe extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _Lobe({required this.icon, required this.color, required this.onTap});

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
          onPressed: onTap,
          icon: Icon(icon),
        ),
      ),
    );
  }
}

/// The mini folded small: art + pause, nothing else. Width fixed so the
/// split row holds its shape across track changes.
class _CompactMini extends ConsumerWidget {
  const _CompactMini();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.watch(currentSongProvider).value;
    final playing = ref.watch(playingProvider).value ?? false;
    if (song == null) return const SizedBox.shrink();
    final handler = ref.read(audioHandlerProvider);
    return LiquidGlassLens(
      style: ArchGlass.circle(radius: 26),
      child: GestureDetector(
        onTap: () => ref.read(playerOpenProvider.notifier).state = true,
        child: Container(
          width: NowPlayingDock.compactWidth,
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
              const Spacer(),
              SizedBox(
                width: 44,
                height: 44,
                child: IconButton(
                  iconSize: 26,
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
