import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/art_tone.dart';
import '../../core/badges.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../player/morph_icon.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../shell/dock.dart';
import 'album_page.dart' show AlbumPage;
import 'library_providers.dart';
import 'remote_album_page.dart';
import 'song_row.dart';

/// One discography category as a real destination: washed hero with
/// an art mosaic, title + count, Play-all-owned / Shuffle, then a
/// 2-col grid. Owned tiles open the local album; unowned tiles open
/// the remote album page — no dead tiles anywhere.
class ReleaseGallery extends ConsumerStatefulWidget {
  final String artistName;
  final String label;
  final List<ReleaseGroup> items;
  final Set<String> ownedTitles;

  const ReleaseGallery({
    super.key,
    required this.artistName,
    required this.label,
    required this.items,
    required this.ownedTitles,
  });

  @override
  ConsumerState<ReleaseGallery> createState() => _ReleaseGalleryState();
}

class _ReleaseGalleryState extends ConsumerState<ReleaseGallery> {
  Color? _washTarget;

  Album? _matchLocal(ReleaseGroup r, List<Album> albums) {
    for (final a in albums) {
      if (normTitle(a.title) != normTitle(r.title)) continue;
      if (a.songs.any((s) => artistsOverlap(s.artist, widget.artistName))) {
        return a;
      }
    }
    return null;
  }

  List<Song> _ownedSongs(List<Album> albums) {
    final out = <Song>[];
    for (final r in widget.items) {
      final a = _matchLocal(r, albums);
      if (a != null) out.addAll(a.songs);
    }
    return out;
  }

  Future<void> _playAll(List<Song> queue, bool shuffle) async {
    if (queue.isEmpty) return;
    HapticFeedback.mediumImpact();
    final handler = ref.read(audioHandlerProvider);
    if (shuffle) {
      await playAndOpen(
        ref,
        context,
        () => handler.playShuffled(queue),
      );
    } else {
      await playAndOpen(
        ref,
        context,
        () => handler.playSong(queue.first, queue),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final albums = ref.watch(albumsProvider);
    final owned = _ownedSongs(albums);
    final collapsed = ref.watch(pillCollapsedProvider);
    final mini = ref.watch(miniVisibleProvider);
    final bottomClear = collapsed
        ? 120.0
        : (mini ? 200.0 : 140.0);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final amoled = isAmoledScheme(context);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(
        begin: ArtTone.pageWashOf(null, dark: dark, amoled: amoled),
        end: _washTarget ??
            ArtTone.pageWashOf(null, dark: dark, amoled: amoled),
      ),
      duration: Motion.reduced(context)
          ? Duration.zero
          : const Duration(milliseconds: 400),
      builder: (context, wash, _) {
        final page = wash ??
            ArtTone.pageWashOf(null, dark: dark, amoled: amoled);
        return Scaffold(
          backgroundColor: page,
          body: DockScrollReporter(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomScrollView(
                  slivers: [
                    _GalleryHero(
                      artistName: widget.artistName,
                      label: widget.label,
                      count: widget.items.length,
                      items: widget.items.take(4).toList(),
                      wash: page,
                      onWash: (c) {
                        if (!mounted || c == _washTarget) return;
                        setState(() => _washTarget = c);
                      },
                      onBack: () => Navigator.of(context).maybePop(),
                      onPlay: () => _playAll(owned, false),
                      onShuffle: () => _playAll(owned, true),
                      canPlay: owned.isNotEmpty,
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      sliver: SliverGrid(
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 20,
                          mainAxisExtent:
                              (MediaQuery.sizeOf(context).width - 56) / 2 + 48,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final r = widget.items[i];
                            final a = _matchLocal(r, albums);
                            final isOwned = a != null;
                            return CascadeIn(
                              delayMs: (i.clamp(0, 9)) * 30,
                              child: GestureDetector(
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  if (a != null) {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => AlbumPage(album: a),
                                      ),
                                    );
                                    return;
                                  }
                                  RemoteAlbumPage.open(
                                    context,
                                    widget.artistName,
                                    r.title,
                                  );
                                },
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: ReleaseCover(
                                        release: r,
                                        owned: isOwned,
                                        fill: true,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      r.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: isOwned
                                            ? Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                            : Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (r.year != null)
                                      Row(
                                        children: [
                                          Text(
                                            '${r.year}',
                                            style: TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                                fontSize: 12),
                                          ),
                                          if (r.type == 'single' || r.type == 'ep') ...[
                                            const SizedBox(width: 6),
                                            TypeBadge(label: r.type.toUpperCase()),
                                          ],
                                        ],
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                          childCount: widget.items.length,
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                        child: SizedBox(height: bottomClear)),
                  ],
                ),
                const NowPlayingDock(),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Washed hero: back chip, mosaic of the section's first covers,
/// label + count. Tone follows the first cover with art.
class _GalleryHero extends StatelessWidget {
  final String artistName;
  final String label;
  final int count;
  final List<ReleaseGroup> items;
  final Color wash;
  final ValueChanged<Color>? onWash;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final bool canPlay;

  const _GalleryHero({
    required this.artistName,
    required this.label,
    required this.count,
    required this.items,
    required this.wash,
    this.onWash,
    required this.onBack,
    required this.onPlay,
    required this.onShuffle,
    required this.canPlay,
  });

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final amoled = isAmoledScheme(context);
    if (items.isNotEmpty) {
      ArtTone.paletteOf(items.first.artUrl).then((pal) {
        if (pal == null) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onWash?.call(ArtTone.pageWashOf(pal.wash, dark: dark, amoled: amoled));
        });
      });
    }
    return SliverAppBar(
      expandedHeight: 400,
      pinned: true,
      backgroundColor: wash,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      shadowColor: Colors.transparent,
      leading: Padding(
        padding: const EdgeInsets.all(8),
        child: LiquidGlassLens(
          style: ArchGlass.circle(
              radius: 24, amoled: isAmoledScheme(context)),
          child: IconButton(
            onPressed: onBack,
            icon: Icon(Icons.arrow_back,
                color: Theme.of(context).colorScheme.onSurface),
          ),
        ),
      ),
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          const expanded = 400.0;
          final collapse =
              ((expanded - constraints.maxHeight) /
                      (expanded - (kToolbarHeight + topPad)))
                  .clamp(0.0, 1.0);
          return FlexibleSpaceBar(
            collapseMode: CollapseMode.pin,
            background: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: topPad + kToolbarHeight + 8,
                  bottom: 8,
                  child: Opacity(
                    opacity: 1 - collapse,
                    child: Column(
                      children: [
                        LayoutBuilder(
                          builder: (context, rowConstraints) {
                            // Adaptive mosaic: four covers always fit,
                            // no fixed widths, no overflow on narrow phones.
                            final n = items.length.clamp(1, 4);
                            final size =
                                ((rowConstraints.maxWidth - 32 - (n - 1) * 8) /
                                        n)
                                    .clamp(64.0, 120.0);
                            return SizedBox(
                              height: size,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  for (var i = 0; i < n; i++)
                                    Container(
                                      margin: EdgeInsets.only(
                                        left: i == 0 ? 0 : 8,
                                      ),
                                      child: ReleaseCover(
                                        release: items[i],
                                        owned: false,
                                        size: size,
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        Text(
                          label,
                          style: const TextStyle(
                            fontFamily: 'ArchSerif',
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                        ),
                        Text(
                          '$count release${count == 1 ? '' : 's'}',
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 13),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            GestureDetector(
                              onTap: canPlay ? onShuffle : null,
                              child: Opacity(
                                opacity: canPlay ? 1.0 : 0.35,
                                child: Container(
                                  width: 52,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.08),
                                    ),
                                  ),
                                  child: Icon(
                                    CupertinoIcons.shuffle_medium,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface,
                                    size: 24,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            GestureDetector(
                              onTap: canPlay ? onPlay : null,
                              child: Opacity(
                                opacity: canPlay ? 1.0 : 0.35,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 40,
                                    vertical: 14,
                                  ),
                                  decoration: const BoxDecoration(
                                    color: archPink,
                                    borderRadius: BorderRadius.all(
                                      Radius.circular(28),
                                    ),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        CupertinoIcons.play_fill,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                      SizedBox(width: 4),
                                      Text(
                                        'Play',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: topPad + 12,
                  left: 64,
                  right: 64,
                  child: Opacity(
                    opacity: collapse,
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
