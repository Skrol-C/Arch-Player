import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../library/artist_page.dart';
import '../library/library_providers.dart';
import '../library/library_screen.dart' show AlbumPage;
import '../library/song_row.dart';
import '../lyrics/lyrics_view.dart';
import 'audio_handler.dart';
import 'format_marks.dart';
import 'morph_icon.dart';
import 'play_guarded.dart';
import 'player_providers.dart';
import 'track_menu.dart';
import 'current_art.dart';
import '../song/song_page.dart';

/// Full player, Apple anatomy in our skin: ambient artwork wash,
/// morphing art stage (full cover <-> 72px header + panel), scrub
/// with buffered fill, one 5-wide transport row, lyrics/queue/sleep
/// below. Panels crossfade in place; the cover travels between its
/// two sizes. Reduced-motion cuts everything to fades.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.watch(currentSongProvider).value;
    if (song == null) {
      return Scaffold(
        backgroundColor: paper,
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(CupertinoIcons.music_note, color: inkDim, size: 64),
                const SizedBox(height: 12),
                const Text(
                  'Nothing playing',
                  style: TextStyle(
                    color: ink,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Pick a song from the library',
                  style: TextStyle(color: inkDim),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () =>
                      ref.read(playerOpenProvider.notifier).state = false,
                  child: const Text(
                    'Back to library',
                    style: TextStyle(
                      color: archPink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    // Adaptive artwork wash: crossfades per track (their 380ms -
    // calm, not sluggish). Paper fallback, never the accent.
    final palette = ref.watch(playerPaletteProvider).value;
    final wash = playerWashOf(palette);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: paper,
        body: AnimatedContainer(
          duration: Motion.reduced(context)
              ? Duration.zero
              : const Duration(milliseconds: 380),
          curve: Curves.easeInOut,
          color: wash,
          child: SafeArea(
            child: _ImmersionScope(
              child: Column(
                children: [
                  _Immersed(
                    child: _DismissDrag(
                      child: _TopBar(
                        onMore: () => _openPlayerMenu(ref, context, song),
                      ),
                    ),
                  ),
                  Expanded(child: _Stage(song: song)),
                  _Immersed(child: _Scrub(song: song)),
                  const _Immersed(child: _Transport()),
                  const _Immersed(child: _UtilityRow()),
                  // Lift: the cluster floats with air below instead of
                  // touching the screen bottom. One constant to tune.
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The morphing stage: full cover (art + titles) at rest, 72px header
/// + panel when lyrics or queue take over. One 380ms driver - cover
/// and panel travel together, never on separate timings.
class _Stage extends ConsumerWidget {
  final Song song;
  const _Stage({required this.song});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = ref.watch(playerPanelProvider);
    final compact = panel != PlayerPanel.none;
    final playing = ref.watch(playingProvider).value ?? false;
    final artSize = math.min(MediaQuery.widthOf(context) - 64, 360.0);
    // Hoisted layers: built once per build and reused as identical
    // instances on every animation tick, so ticks only recompute the
    // cheap wrappers (opacity/offset/scale) and never reconcile the
    // heavy subtrees (art, lyric list, queue list) below them.
    final heroLayer = _DragHero(song: song, artSize: artSize);
    final headerLayer = _CompactHeader(song: song);
    final panelLayer = _PanelStack(panel: panel, songId: song.id);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: compact ? 1.0 : 0.0),
      duration: Motion.reduced(context)
          ? Duration.zero
          : const Duration(milliseconds: 380),
      curve: Curves.easeInOutCubic,
      builder: (context, t, _) {
        return Stack(
          fit: StackFit.expand,
          children: [
            // Compact header: 72px art + titles, slides down from top.
            Positioned(
              top: 0,
              left: 20,
              right: 20,
              child: Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, -16 * (1 - t)),
                  child: t < 0.02 ? const SizedBox.shrink() : headerLayer,
                ),
              ),
            ),
            // Panel: lyrics or queue filling below the compact header.
            Positioned.fill(
              top: 104,
              child: Opacity(
                opacity: t,
                child: t < 0.02 ? const SizedBox.shrink() : panelLayer,
              ),
            ),
            // Full cover: art + titles, settling out as the panel lands.
            Opacity(
              opacity: 1 - t,
              child: Transform.scale(
                scale: (1 - 0.08 * t) * (playing ? 1.0 : 0.94),
                child: t > 0.98 ? const SizedBox.shrink() : heroLayer,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Both panels stay mounted for the song; switching crossfades
/// instead of remounting, so panel changes never pay list layout,
/// controller loads, or art lookups mid-gesture. Offstage in cover
/// mode so hidden panels keep state but skip layout entirely.
class _PanelStack extends StatelessWidget {
  final PlayerPanel panel;
  final int songId;
  const _PanelStack({required this.panel, required this.songId});

  @override
  Widget build(BuildContext context) {
    final lyrics = panel == PlayerPanel.lyrics;
    final fade = Motion.reduced(context) ? Duration.zero : Motion.stateChange;
    return Offstage(
      offstage: panel == PlayerPanel.none,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedOpacity(
            opacity: lyrics ? 1.0 : 0.0,
            duration: fade,
            curve: Curves.easeOut,
            child: IgnorePointer(ignoring: !lyrics, child: const LyricsSlot()),
          ),
          AnimatedOpacity(
            opacity: lyrics ? 0.0 : 1.0,
            duration: fade,
            curve: Curves.easeOut,
            child: IgnorePointer(
              ignoring: lyrics,
              child: _QueuePanel(key: ValueKey(songId)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 72px cover header for panel mode: art, titles, nav menu on tap,
/// swipe down returns to the full cover.
class _CompactHeader extends ConsumerWidget {
  final Song song;
  const _CompactHeader({required this.song});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 500) {
          HapticFeedback.selectionClick();
          ref.read(playerPanelProvider.notifier).state = PlayerPanel.none;
        }
      },
      onTap: () => SongPage.open(context, playerTitleRef(ref, song)),
      child: Row(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: SizedBox(
              key: ValueKey(song.albumId),
              width: 72,
              height: 72,
              child: CurrentArt(
                song: song,
                size: 72,
                radius: 14,
                iconSize: 32,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: inkDim, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Immersion scope: while the lyrics panel is open, 3s without a
/// touch melts the chrome (top bar, scrub, transport, utility row),
/// leaving the banner + words. Any tap restores and restarts the
/// clock. Other panels never immerse - the timer only arms on
/// lyrics, and panel changes clear it outright.
class _ImmersionScope extends ConsumerStatefulWidget {
  final Widget child;
  const _ImmersionScope({required this.child});

  @override
  ConsumerState<_ImmersionScope> createState() => _ImmersionScopeState();
}

class _ImmersionScopeState extends ConsumerState<_ImmersionScope> {
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm() {
    _timer?.cancel();
    if (!mounted || ref.read(playerPanelProvider) != PlayerPanel.lyrics) {
      return;
    }
    _timer = Timer(const Duration(seconds: 3), () {
      if (mounted && ref.read(playerPanelProvider) == PlayerPanel.lyrics) {
        ref.read(immersionProvider.notifier).state = true;
      }
    });
  }

  void _poke() {
    if (ref.read(immersionProvider)) {
      ref.read(immersionProvider.notifier).state = false;
    }
    _arm();
  }

  @override
  Widget build(BuildContext context) {
    final panel = ref.watch(playerPanelProvider);
    if (panel != PlayerPanel.lyrics && ref.read(immersionProvider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(immersionProvider.notifier).state = false;
        }
      });
    }
    // Arm on arrival: mount + panel switches both build here.
    // Taps re-arm via poke; the active timer is never restarted
    // under itself.
    if (panel == PlayerPanel.lyrics && (_timer == null || !_timer!.isActive)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _arm());
    }
    return Listener(
      onPointerDown: (_) => _poke(),
      behavior: HitTestBehavior.translucent,
      child: widget.child,
    );
  }
}

/// One chrome piece under immersion: melts to nothing (keeps its
/// layout slot, so nothing jumps) and stops taking taps.
class _Immersed extends ConsumerWidget {
  final Widget child;
  const _Immersed({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final immersed = ref.watch(immersionProvider);
    return IgnorePointer(
      ignoring: immersed,
      child: AnimatedOpacity(
        opacity: immersed ? 0 : 1,
        duration: Motion.reduced(context)
            ? Duration.zero
            : const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        child: child,
      ),
    );
  }
}

/// Grip + glass more (actions menu). The whole bar is a dismiss
/// drag zone (full width, generous thresholds) - the grip is finally
/// honest. The more button keeps working: taps and vertical drags
/// are compatible recognizers, small movements still tap.
class _DismissDrag extends ConsumerWidget {
  final Widget child;
  const _DismissDrag({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var dy = 0.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) => dy += d.delta.dy,
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v > 400 || dy > 90) {
          HapticFeedback.mediumImpact();
          ref.read(playerOpenProvider.notifier).state = false;
        }
        dy = 0;
      },
      onVerticalDragCancel: () => dy = 0,
      child: Container(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        color: Colors.transparent,
        child: child,
      ),
    );
  }
}

/// Grip + glass more (actions menu). Dismissal is the hero drag and
/// the system back button; the grip is the visual affordance.
class _TopBar extends StatelessWidget {
  final VoidCallback? onMore;
  const _TopBar({this.onMore});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: inkDim.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: LiquidGlassLens(
              style: ArchGlass.circle(radius: 24),
              child: SizedBox(
                width: 48,
                height: 48,
                child: IconButton(
                  icon: const Icon(CupertinoIcons.ellipsis, color: ink),
                  iconSize: 26,
                  onPressed: onMore == null
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          onMore!();
                        },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Art + title block. Gestures live only while no panel is up
/// (panels own their own gestures - no arena fights). Vertical drags
/// dismiss or expand lyrics; horizontal flings change tracks with a
/// directional handoff.
class _DragHero extends ConsumerStatefulWidget {
  final Song song;
  final double artSize;
  const _DragHero({required this.song, required this.artSize});

  @override
  ConsumerState<_DragHero> createState() => _DragHeroState();
}

class _DragHeroState extends ConsumerState<_DragHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _snap;
  Animation<double>? _returning;
  double _dragY = 0;

  /// Last horizontal fling direction: the track-change handoff slides
  /// toward it, so swipes read directionally instead of crossfading.
  double _swipeDir = 0;

  @override
  void initState() {
    super.initState();
    _snap = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _snap.addListener(() {
      if (mounted && _returning != null) {
        setState(() => _dragY = _returning!.value);
      }
    });
  }

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  void _springBack() {
    _returning = Tween(
      begin: _dragY,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _snap, curve: Curves.easeOutBack));
    _snap.forward(from: 0);
  }

  bool get _panelUp => ref.read(playerPanelProvider) != PlayerPanel.none;

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final isPreview = song.folderKey == 'preview' || song.id < 0;
    return GestureDetector(
      onVerticalDragUpdate: (d) {
        if (Motion.reduced(context) || _panelUp) return;
        _snap.stop();
        setState(() => _dragY = (_dragY + d.delta.dy).clamp(-220.0, 400.0));
      },
      onVerticalDragEnd: (d) {
        if (_panelUp) return;
        final v = d.primaryVelocity ?? 0;
        if (_dragY > 140 || v > 700) {
          // Drag down: dismiss.
          HapticFeedback.mediumImpact();
          ref.read(playerOpenProvider.notifier).state = false;
          if (mounted) setState(() => _dragY = 0);
        } else if (_dragY < -120 || v < -700) {
          // Swipe up: full-screen lyrics.
          HapticFeedback.mediumImpact();
          if (mounted) setState(() => _dragY = 0);
          ref.read(playerPanelProvider.notifier).state = PlayerPanel.lyrics;
          LyricsSlot.jumpToActive(ref);
        } else {
          _springBack();
        }
      },
      // Swipe sideways: track change. The arena disambiguates against
      // the vertical drags above - one gesture wins, never both.
      onHorizontalDragEnd: (d) {
        if (_panelUp) return;
        final v = d.primaryVelocity ?? 0;
        final handler = ref.read(audioHandlerProvider);
        if (v < -500) {
          HapticFeedback.mediumImpact();
          setState(() => _swipeDir = -1);
          playGuarded(context, () => handler.skipToNext());
        } else if (v > 500) {
          HapticFeedback.mediumImpact();
          setState(() => _swipeDir = 1);
          playGuarded(context, () => handler.skipToPrevious());
        }
      },
      child: Transform.translate(
        offset: Offset(0, _dragY),
        child: Opacity(
          opacity: (1 - _dragY / 500).clamp(0.0, 1.0),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              // Bottom-packed: art + titles ground above the scrub
              // instead of floating centered, so the whole cluster
              // rises as one body. Empty wash collects up top.
              // Max size is load-bearing: end-packing needs the full
              // stage height, not a min wrap.
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Art floats above the titles on its own: one constant,
                // titles stay grounded. Nests inside the drag-follow
                // above, unaffected by it.
                Transform.translate(
                  offset: const Offset(0, -20),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    // Directional handoff: incoming art slides in from the
                    // swipe side; programmatic changes fade-settle in place.
                    transitionBuilder: (child, anim) {
                      if (Motion.reduced(context)) {
                        return FadeTransition(opacity: anim, child: child);
                      }
                      return FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: anim.drive(
                            Tween(
                              begin: Offset(0.35 * _swipeDir, 0.04),
                              end: Offset.zero,
                            ).chain(CurveTween(curve: Motion.arrival)),
                          ),
                          child: ScaleTransition(
                            scale: anim.drive(
                              Tween(
                                begin: 0.96,
                                end: 1.0,
                              ).chain(CurveTween(curve: Motion.arrival)),
                            ),
                            child: child,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      key: ValueKey(song.albumId),
                      width: widget.artSize,
                      height: widget.artSize,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x1A000000),
                            blurRadius: 32,
                            offset: Offset(0, 12),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: CurrentArt(
                          song: song,
                          size: 0,
                          radius: 0,
                          iconSize: 96,
                          fill: true,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (isPreview)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: archPink.withValues(alpha: 0.6),
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'PREVIEW - 30s',
                      style: TextStyle(
                        color: archPink,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, anim) {
                    if (Motion.reduced(context)) {
                      return FadeTransition(opacity: anim, child: child);
                    }
                    return FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: anim.drive(
                          Tween(
                            begin: Offset(0.25 * _swipeDir, 0.15),
                            end: Offset.zero,
                          ).chain(CurveTween(curve: Motion.arrival)),
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: GestureDetector(
                    key: ValueKey(song.id),
                    onTap: () =>
                        SongPage.open(context, playerTitleRef(ref, song)),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: artistVoiceOf(song.artist),
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              letterSpacing: voiceSpacing(
                                artistVoiceOf(song.artist),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  song.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: inkDim),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FormatChip(path: song.path),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Scrub with buffered fill and seek preview. Drags preview locally
/// (big time readout above the bar); the engine seeks on release -
/// no seek storms.
class _Scrub extends ConsumerStatefulWidget {
  final Song song;
  const _Scrub({required this.song});

  @override
  ConsumerState<_Scrub> createState() => _ScrubState();
}

class _ScrubState extends ConsumerState<_Scrub> {
  double? _dragMs;
  // Fine-scrub anchors: the landing time plus where the thumb
  // started, so vertical distance can gear the sensitivity down.
  double? _anchorMs;
  Offset? _anchorGlobal;
  double _anchorWidth = 1;

  double _sensitivity(double dyDown) {
    if (dyDown <= 0) return 1.0;
    // 1:1 at the bar, easing to ~10% a screen away. Coarse jumps
    // up top, surgical placement below - one gesture, both jobs.
    return (1.0 - (dyDown / 140) * 0.9).clamp(0.1, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final totalMs = song.duration.inMilliseconds;
    final max = (totalMs > 0 ? totalMs : 1).toDouble();
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final shownMs = (_dragMs ?? position.inMilliseconds.toDouble()).clamp(
      0.0,
      max,
    );
    final remainingMs = (totalMs - shownMs.toInt()).clamp(0, totalMs);
    final handler = ref.read(audioHandlerProvider);
    final dragging = _dragMs != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
      child: Column(
        children: [
          // Seek preview: the dragged time reads large above the bar,
          // then settles back. Nothing while resting.
          AnimatedOpacity(
            duration: Motion.stateChange,
            opacity: dragging ? 1 : 0,
            child: SizedBox(
              height: dragging ? 34 : 0,
              child: dragging
                  ? Center(
                      child: Text(
                        fmtDuration(Duration(milliseconds: shownMs.toInt())),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          // Glass ribbon seek: the line itself is a thin refractive
          // strip, pink living inside the glass. Thumbless always -
          // touch brightens the ribbon and raises the readout, the
          // shape never morphs. One fill layer only (audit: the old
          // double-fill ghost was the capsule's white track meeting
          // the pink at rounded ends - both are gone with it).
          LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final frac = max > 0 ? (shownMs / max).clamp(0.0, 1.0) : 0.0;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (d) {
                  _anchorMs = shownMs;
                  _anchorGlobal = d.globalPosition;
                  _anchorWidth = w;
                  setState(() => _dragMs = shownMs.clamp(0.0, max));
                },
                onHorizontalDragUpdate: (d) {
                  final anchor = _anchorMs;
                  final origin = _anchorGlobal;
                  if (anchor == null || origin == null) return;
                  final dx = d.globalPosition.dx - origin.dx;
                  final dyDown = d.globalPosition.dy - origin.dy;
                  final ms =
                      (anchor + dx / _anchorWidth * max * _sensitivity(dyDown))
                          .clamp(0.0, max);
                  // Deadband: sub-0.2% tremble never moves the fill.
                  if ((ms - (_dragMs ?? anchor)).abs() < max * 0.002) {
                    return;
                  }
                  setState(() => _dragMs = ms);
                },
                onHorizontalDragEnd: (_) {
                  final v = _dragMs;
                  _anchorMs = null;
                  _anchorGlobal = null;
                  setState(() => _dragMs = null);
                  if (v == null) return;
                  playGuarded(
                    context,
                    () => handler.seek(Duration(milliseconds: v.toInt())),
                  );
                  LyricsSlot.jumpToActive(ref);
                },
                onHorizontalDragCancel: () {
                  _anchorMs = null;
                  _anchorGlobal = null;
                  setState(() => _dragMs = null);
                },
                child: Container(
                  // Fat touch target, thin visual: sensitivity lives
                  // in the gesture, not in a fat bar.
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  color: Colors.transparent,
                  child: AnimatedContainer(
                    duration: Motion.reduced(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    height: dragging ? 16 : 10,
                    child: LiquidGlassLens(
                      style: ArchGlass.capsule(radius: 8),
                      child: Container(
                        alignment: Alignment.center,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: Container(
                            height: dragging ? 10 : 5,
                            color: Colors.white.withValues(
                              alpha: dragging ? 0.35 : 0.22,
                            ),
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: frac,
                              child: Container(color: archPink),
                            ),
                          ),
                        ),
                      ),
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
                '-${fmtDuration(Duration(milliseconds: remainingMs))}',
                style: const TextStyle(color: inkDim, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One Apple row: shuffle | prev | PLAY | next | repeat. Shuffle and
/// repeat ride the persisted engine states; the play circle breathes
/// with state (60 playing, 54 paused); transport parks while
/// buffering.
class _Transport extends ConsumerWidget {
  const _Transport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(playingProvider).value ?? false;
    final loading = ref.watch(bufferingProvider).value ?? false;
    final shuffle = ref.watch(shuffleProvider);
    final loop = ref.watch(loopProvider);
    final handler = ref.read(audioHandlerProvider);
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            iconSize: 26,
            color: shuffle ? archPink : inkDim,
            tooltip: 'Shuffle',
            onPressed: () {
              HapticFeedback.selectionClick();
              ref.read(shuffleProvider.notifier).toggle();
            },
            icon: MorphIcon(
              iconKey: shuffle,
              child: const Icon(CupertinoIcons.shuffle_medium),
            ),
          ),
          IconButton(
            iconSize: 44,
            color: ink,
            onPressed: loading
                ? null
                : () => playGuarded(context, () => handler.skipToPrevious()),
            icon: const Icon(CupertinoIcons.backward_end_fill),
          ),
          IconButton(
            iconSize: 58,
            color: archPink,
            onPressed: loading
                ? null
                : () => playGuarded(
                    context,
                    () => playing ? handler.pause() : handler.play(),
                  ),
            icon: MorphIcon(
              iconKey: playing,
              child: Icon(
                playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
              ),
            ),
          ),
          IconButton(
            iconSize: 44,
            color: ink,
            onPressed: loading
                ? null
                : () => playGuarded(context, () => handler.skipToNext()),
            icon: const Icon(CupertinoIcons.forward_end_fill),
          ),
          IconButton(
            iconSize: 26,
            color: loop == LoopMode.off ? inkDim : archPink,
            tooltip: 'Repeat',
            onPressed: () {
              HapticFeedback.selectionClick();
              ref.read(loopProvider.notifier).cycle();
            },
            icon: MorphIcon(
              iconKey: loop,
              child: Icon(
                loop == LoopMode.one
                    ? CupertinoIcons.repeat_1
                    : CupertinoIcons.repeat,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lyrics - queue - sleep as floating glass circles. Glass lives on
/// floating controls only - this row qualifies, content never does.
/// Each toggles its panel (tap again returns to cover); sleep opens
/// its sheet. Share and navigation live in the top-right menu.
class _UtilityRow extends ConsumerWidget {
  const _UtilityRow();

  void _togglePanel(WidgetRef ref, PlayerPanel panel) {
    final current = ref.read(playerPanelProvider);
    ref.read(playerPanelProvider.notifier).state = current == panel
        ? PlayerPanel.none
        : panel;
    if (current != panel && panel == PlayerPanel.lyrics) {
      LyricsSlot.jumpToActive(ref);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = ref.watch(playerPanelProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _GlassAction(
            icon: MorphIcon(
              iconKey: panel == PlayerPanel.queue,
              child: const Icon(CupertinoIcons.list_bullet),
            ),
            tooltip: 'Queue',
            selected: panel == PlayerPanel.queue,
            onTap: () => _togglePanel(ref, PlayerPanel.queue),
          ),
          _GlassAction(
            icon: MorphIcon(
              iconKey: panel == PlayerPanel.lyrics,
              child: const Icon(CupertinoIcons.quote_bubble_fill),
            ),
            tooltip: 'Lyrics',
            selected: panel == PlayerPanel.lyrics,
            onTap: () => _togglePanel(ref, PlayerPanel.lyrics),
          ),
        ],
      ),
    );
  }
}

class _GlassAction extends StatelessWidget {
  final Widget icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool selected;

  const _GlassAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return LiquidGlassLens(
      style: ArchGlass.circle(radius: 28),
      child: SizedBox(
        width: 56,
        height: 56,
        child: IconButton(
          iconSize: 26,
          color: selected ? archPink : ink,
          tooltip: tooltip,
          onPressed: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap!();
                },
          // Selection punch: the glyph springs with the state.
          icon: AnimatedScale(
            scale: selected ? 1.15 : 1.0,
            duration: Motion.reduced(context)
                ? Duration.zero
                : Motion.stateChange,
            curve: Curves.easeOutBack,
            child: icon,
          ),
        ),
      ),
    );
  }
}

/// Up Next panel: mode buttons + shuffle-library + full editing list.
/// Header mirrors the transport states; rows tap-jump, drag-reorder
/// (handle), swipe-remove; the current row is locked and lit.
class _QueuePanel extends ConsumerWidget {
  const _QueuePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider).value ?? [];
    final currentId = ref.watch(currentSongProvider).value?.id;
    final handler = ref.read(audioHandlerProvider);
    final shuffle = ref.watch(shuffleProvider);
    final loop = ref.watch(loopProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 16, 4),
          child: Row(
            children: [
              Text(
                'Up Next',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              _PanelModeBtn(
                icon: Icon(
                  CupertinoIcons.infinite,
                  size: 20,
                  color: inkDim.withValues(alpha: 0.4),
                ),
                tooltip: 'Autoplay',
                active: false,
                dimmed: true,
                onTap: () {
                  HapticFeedback.selectionClick();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Autoplay arrives with harmonic flow'),
                    ),
                  );
                },
              ),
              const SizedBox(width: 4),
              _PanelModeBtn(
                icon: MorphIcon(
                  iconKey: loop,
                  child: Icon(
                    loop == LoopMode.one
                        ? CupertinoIcons.repeat_1
                        : CupertinoIcons.repeat,
                  ),
                ),
                tooltip: 'Repeat',
                active: loop != LoopMode.off,
                onTap: () => ref.read(loopProvider.notifier).cycle(),
              ),
              const SizedBox(width: 4),
              _PanelModeBtn(
                icon: MorphIcon(
                  iconKey: shuffle,
                  child: const Icon(CupertinoIcons.shuffle_medium),
                ),
                tooltip: 'Shuffle',
                active: shuffle,
                onTap: () => ref.read(shuffleProvider.notifier).toggle(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => _shuffleLibrary(ref, context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: archPink.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          CupertinoIcons.shuffle_medium,
                          color: archPink,
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Shuffle Library',
                          style: TextStyle(
                            color: archPink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: queue.isEmpty
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        playGuarded(context, () => handler.clearQueue());
                      },
                child: const Text(
                  'Clear',
                  style: TextStyle(
                    color: archPink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: queue.isEmpty
              ? const Center(
                  child: Text(
                    'Queue is empty - play something.',
                    style: TextStyle(color: inkDim),
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                  itemCount: queue.length,
                  onReorderItem: (oldIndex, newIndex) {
                    HapticFeedback.selectionClick();
                    playGuarded(
                      context,
                      () => handler.moveQueueIndex(oldIndex, newIndex),
                    );
                  },
                  proxyDecorator: (child, _, _) => Material(
                    elevation: 4,
                    color: paper,
                    borderRadius: BorderRadius.circular(12),
                    child: child,
                  ),
                  itemBuilder: (context, i) {
                    final song = queue[i];
                    final current = song.id == currentId;
                    return Dismissible(
                      key: ValueKey('queue-${song.id}-$i'),
                      direction: DismissDirection.endToStart,
                      confirmDismiss: (_) async => !current,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        color: archPink.withValues(alpha: 0.12),
                        child: const Icon(
                          CupertinoIcons.trash,
                          color: archPink,
                        ),
                      ),
                      onDismissed: (_) => playGuarded(
                        context,
                        () => handler.removeQueueIndex(i),
                      ),
                      child: ListTile(
                        selected: current,
                        selectedTileColor: archPink.withValues(alpha: 0.1),
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 4,
                        ),
                        onTap: () => playGuarded(
                          context,
                          () => handler.playSong(song, queue),
                        ),
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox.square(
                            dimension: 44,
                            child: CurrentArt(
                              song: song,
                              size: 44,
                              radius: 8,
                              iconSize: 22,
                              // Rows paint their own art, never the
                              // live item's file (queue-wide inherit
                              // bug otherwise).
                              useLiveFile: false,
                            ),
                          ),
                        ),
                        title: Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: current
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: current ? archPink : ink,
                          ),
                        ),
                        subtitle: Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: inkDim, fontSize: 13),
                        ),
                        trailing: ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(
                              CupertinoIcons.line_horizontal_3,
                              color: inkDim,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _shuffleLibrary(WidgetRef ref, BuildContext context) async {
    final songs = ref.read(songsProvider).value ?? [];
    if (songs.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Library is empty')));
      }
      return;
    }
    final shuffled = List<Song>.from(songs)..shuffle();
    final handler = ref.read(audioHandlerProvider);
    HapticFeedback.mediumImpact();
    await handler.setShuffleEnabled(true);
    if (!context.mounted) return;
    await playAndOpen(
      ref,
      context,
      () => handler.playSong(shuffled.first, shuffled),
    );
  }
}

class _PanelModeBtn extends StatelessWidget {
  final Widget icon;
  final String tooltip;
  final bool active;
  final bool dimmed;
  final VoidCallback onTap;

  const _PanelModeBtn({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: active ? archPink.withValues(alpha: 0.14) : paperRaised,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: IconTheme(
            data: IconThemeData(
              size: 20,
              color: active
                  ? archPink
                  : dimmed
                  ? inkDim.withValues(alpha: 0.4)
                  : inkDim,
            ),
            child: icon,
          ),
        ),
      ),
    );
  }
}

/// Sleep chips: off + presets. Shows the live countdown while armed.
class _SleepSheet extends ConsumerWidget {
  const _SleepSheet();

  static const _options = <Duration?>[
    null,
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(hours: 1),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sleep = ref.watch(sleepProvider).value;
    final handler = ref.read(audioHandlerProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sleep timer', style: Theme.of(context).textTheme.titleLarge),
            if (sleep != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  sleepLabel(sleep),
                  style: const TextStyle(color: archPink),
                ),
              ),
            const SizedBox(height: 12),
            for (var i = 0; i < _options.length; i++)
              CascadeIn(
                delayMs: i * 30,
                child: _SleepOption(
                  d: _options[i],
                  sleep: sleep,
                  handler: handler,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One sleep row: label + selected check, arms/cancels on tap.
class _SleepOption extends StatelessWidget {
  final Duration? d;
  final Duration? sleep;
  final ArchAudioHandler handler;

  const _SleepOption({
    required this.d,
    required this.sleep,
    required this.handler,
  });

  static String _label(Duration? d) {
    if (d == null) return 'Off';
    if (d.inHours > 0) return '${d.inHours} hour';
    return '${d.inMinutes} min';
  }

  @override
  Widget build(BuildContext context) {
    // Locals: promotion doesn't narrow fields, so copy first.
    final armed = sleep;
    final option = d;
    final selected =
        (armed == null && option == null) ||
        (armed != null &&
            option != null &&
            (armed - option).abs() < const Duration(minutes: 1));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        _label(d),
        style: const TextStyle(color: ink, fontWeight: FontWeight.w600),
      ),
      trailing: selected
          ? const Icon(CupertinoIcons.checkmark, color: archPink)
          : null,
      onTap: () {
        HapticFeedback.selectionClick();
        final option = d;
        if (option == null) {
          handler.cancelSleep();
        } else {
          handler.startSleep(option);
        }
        Navigator.of(context).pop();
      },
    );
  }
}

/// Player menu: Share quick, Go to Album/Artist, Doctor +
/// Lyric Finder placeholders, Sleep, Details.
/// Same rows as the song menu, plus the live sleep subtitle.
Future<void> _openPlayerMenu(
  WidgetRef ref,
  BuildContext context,
  Song song,
) async {
  final album = ownedAlbumFor(ref, song);
  final sleep = ref.read(sleepProvider).value;
  final value = await showTrackMenu(
    context: context,
    quick: const [
      MenuAction(
        icon: CupertinoIcons.square_arrow_up,
        label: 'Share',
        value: 'share',
      ),
    ],
    groups: [
      [
        if (album != null)
          MenuAction(
            icon: CupertinoIcons.music_albums,
            label: 'Go to Album',
            subtitle: song.album,
            value: 'album',
          ),
        MenuAction(
          icon: CupertinoIcons.person,
          label: 'Go to Artist',
          subtitle: song.artist,
          value: 'artist',
        ),
        const MenuAction(
          icon: CupertinoIcons.bandage,
          label: 'Song Doctor',
          subtitle: 'Coming soon',
          value: 'doctor',
        ),
        const MenuAction(
          icon: CupertinoIcons.text_bubble,
          label: 'Lyric Finder',
          subtitle: 'Coming soon',
          value: 'lyrics',
        ),
        const MenuAction(
          icon: CupertinoIcons.info_circle,
          label: 'Details',
          value: 'details',
        ),
      ],
      [
        MenuAction(
          icon: CupertinoIcons.moon_fill,
          label: 'Sleep timer',
          subtitle: sleepLabel(sleep),
          value: 'sleep',
          selected: sleep != null,
        ),
      ],
    ],
  );
  if (!context.mounted) return;
  switch (value) {
    case 'album':
      if (album != null) {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => AlbumPage(album: album)));
      }
      break;
    case 'artist':
      ArtistPage.openIfAbsent(context, song.artist);
      break;
    case 'doctor':
      case 'lyrics':
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('On the way — not yet available.')),
        );
      }
      break;
    case 'share':
      SharePlus.instance.share(
        ShareParams(text: '${song.title} - ${song.artist}'),
      );
      break;
    case 'sleep':
      showModalBottomSheet(
        context: context,
        builder: (_) => const _SleepSheet(),
      );
      break;
    case 'details':
      showModalBottomSheet(
        context: context,
        builder: (_) => TrackDetailsSheet(song: song),
      );
      break;
  }
}
