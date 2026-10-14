import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../library/song_row.dart';
import 'play_guarded.dart';
import 'player_providers.dart';
import 'morph_icon.dart';

/// Glass capsule mini player, SpotiFLAC mechanisms in our skin: same 340
/// width and lens recipe as the nav pill (one unit, one driver), art +
/// title/artist, glass pause + next circles, pink progress hairline.
/// Horizontal swipe stops and clears; long titles marquee (capped,
/// frozen under reduced-motion). Tap opens the full player.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.watch(currentSongProvider).value;
    final playing = ref.watch(playingProvider).value ?? false;
    if (song == null) return const SizedBox.shrink();
    final handler = ref.read(audioHandlerProvider);
    return Dismissible(
      key: ValueKey('mini-${song.id}'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) async {
        ArchLog.i('player', 'mini dismissed id=${song.id}');
        await playGuarded(context, () => handler.clearQueue());
      },
      child: LiquidGlassLens(
        style: ArchGlass.capsule(radius: 34),
        child: GestureDetector(
          onTap: () => ref.read(playerOpenProvider.notifier).state = true,
          child: Container(
            height: 68,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Stack(
                children: [
                  Row(
                    children: [
                      AnimatedSwitcher(
                        duration: Motion.stateChange,
                        child: SizedBox(
                          key: ValueKey(song.albumId),
                          width: 44,
                          height: 44,
                          child: song.albumId > 0
                              ? AlbumArt(
                                  albumId: song.albumId,
                                  size: 44,
                                  radius: 12,
                                )
                              : Container(
                                  decoration: BoxDecoration(
                                    color: paperRaised,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                    CupertinoIcons.music_note,
                                    color: inkDim,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Marquee(
                              text: song.title,
                              style: TextStyle(
                                color: playing ? archPink : ink,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              song.artist,
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
                      _GlassCircle(
                        icon: MorphIcon(
                          iconKey: playing,
                          child: Icon(
                            playing
                                ? CupertinoIcons.pause_fill
                                : CupertinoIcons.play_fill,
                          ),
                        ),
                        onTap: () => playGuarded(
                          context,
                          () => playing ? handler.pause() : handler.play(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _GlassCircle(
                        icon: const Icon(CupertinoIcons.forward_end_fill),
                        onTap: () =>
                            playGuarded(context, () => handler.skipToNext()),
                      ),
                    ],
                  ),
                  _MiniProgress(total: song.duration),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Progress hairline alone: the only part of the mini that moves
/// with playback position. Isolating it keeps position ticks from
/// rebuilding the glass, art, and marquee above it.
class _MiniProgress extends ConsumerWidget {
  final Duration total;
  const _MiniProgress({required this.total});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final totalMs = total.inMilliseconds;
    final frac = totalMs > 0
        ? (position.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: frac,
        child: Container(height: 2, color: archPink),
      ),
    );
  }
}

/// One circular glass button. Same lens recipe as every other glass in
/// the app - one recipe, or the unit falls apart.
class _GlassCircle extends StatelessWidget {
  final Widget icon;
  final VoidCallback onTap;

  const _GlassCircle({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return LiquidGlassLens(
      style: ArchGlass.circle(radius: 28),
      child: SizedBox(
        width: 48,
        height: 48,
        child: IconButton(
          iconSize: 26,
          color: ink,
          onPressed: onTap,
          icon: icon,
        ),
      ),
    );
  }
}

/// Long titles scroll instead of dying in ellipsis: settle, glide to
/// the end, settle, glide home - two cycles, then rest. Reduced-motion
/// gets plain ellipsis; short titles never move at all.
class _Marquee extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const _Marquee({required this.text, this.style});

  @override
  State<_Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<_Marquee> {
  final _scroller = ScrollController();
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run(++_gen));
  }

  @override
  void didUpdateWidget(_Marquee old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      if (_scroller.hasClients) _scroller.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _run(++_gen));
    }
  }

  Future<void> _run(int gen) async {
    if (!mounted || gen != _gen || Motion.reduced(context)) return;
    await Future.delayed(const Duration(seconds: 2));
    var cycles = 0;
    while (mounted && gen == _gen && cycles < 2) {
      if (!_scroller.hasClients) return;
      final max = _scroller.position.maxScrollExtent;
      if (max <= 0) return;
      await _scroller.animateTo(
        max,
        duration: Duration(milliseconds: (max * 15).clamp(1500, 6000).toInt()),
        curve: Curves.easeInOut,
      );
      if (!mounted || gen != _gen) return;
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted || gen != _gen) return;
      await _scroller.animateTo(
        0,
        duration: const Duration(milliseconds: 800),
        curve: Curves.easeInOut,
      );
      cycles++;
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  @override
  void dispose() {
    _gen++;
    _scroller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) {
      return Text(
        widget.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: widget.style,
      );
    }
    return SingleChildScrollView(
      controller: _scroller,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(widget.text, maxLines: 1, style: widget.style),
    );
  }
}
