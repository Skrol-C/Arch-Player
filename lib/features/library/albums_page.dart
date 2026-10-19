import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../player/track_menu.dart' show MenuAction, showTrackMenu;
import '../shell/dock.dart';
import 'album_card.dart';
import 'library_chrome.dart';
import 'library_controls.dart';
import 'library_providers.dart';

enum _AlbumOrder { title, artist, year }

/// Albums index (WA0013 grammar): back, sort capsule + `...`, Play /
/// Shuffle, search, then covers either as a 2-col grid or a list.
/// `...` owns the view switch; the left half of the capsule owns sort.
class AlbumsPage extends ConsumerStatefulWidget {
  const AlbumsPage({super.key});

  @override
  ConsumerState<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends ConsumerState<AlbumsPage> {
  bool _grid = true;
  _AlbumOrder _order = _AlbumOrder.title;

  List<Album> _ordered(List<Album> input) {
    final list = List<Album>.of(input);
    int yearOf(Album a) {
      var y = 0;
      for (final s in a.songs) {
        if (s.year > y) y = s.year;
      }
      return y;
    }

    switch (_order) {
      case _AlbumOrder.title:
        list.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      case _AlbumOrder.artist:
        list.sort((a, b) {
          final c = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
          return c != 0
              ? c
              : a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
      case _AlbumOrder.year:
        list.sort((a, b) => yearOf(b).compareTo(yearOf(a)));
    }
    return list;
  }

  Future<void> _playAll(List<Album> albums) async {
    final queue = [for (final a in albums) ...a.songs];
    if (queue.isEmpty) return;
    HapticFeedback.mediumImpact();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playSong(queue.first, queue));
  }

  Future<void> _shuffleAll(List<Album> albums) async {
    final queue = [for (final a in albums) ...a.songs];
    if (queue.isEmpty) return;
    HapticFeedback.mediumImpact();
    queue.shuffle();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playSong(queue.first, queue));
  }

  Future<void> _pickSort() async {
    final value = await showLibrarySort<_AlbumOrder>(
      context: context,
      current: _order,
      options: const [
        (label: 'Title', value: _AlbumOrder.title),
        (label: 'Artist', value: _AlbumOrder.artist),
        (label: 'Year', value: _AlbumOrder.year),
      ],
    );
    if (!mounted || value == null || value == _order) return;
    setState(() => _order = value);
  }

  Future<void> _openViewMenu(BuildContext buttonContext) async {
    final value = await showTrackMenu(
      context: buttonContext,
      groups: [
        [
          MenuAction(
            icon: CupertinoIcons.square_grid_2x2,
            label: 'Grid',
            value: 'grid',
            selected: _grid,
          ),
          MenuAction(
            icon: CupertinoIcons.list_bullet,
            label: 'List',
            value: 'list',
            selected: !_grid,
          ),
        ],
      ],
    );
    if (!mounted) return;
    final bool? wantsGrid = switch (value) {
      'grid' => true,
      'list' => false,
      _ => null,
    };
    if (wantsGrid == null || wantsGrid == _grid) return;
    setState(() => _grid = wantsGrid);
  }

  @override
  Widget build(BuildContext context) {
    final albums = _ordered(ref.watch(albumsProvider));
    final collapsed = ref.watch(pillCollapsedProvider);
    final bottomClear = collapsed
        ? 120.0
        : (ref.watch(miniVisibleProvider) ? 200.0 : 140.0);
    return Scaffold(
      backgroundColor: paper,
      body: Stack(
        children: [
          DockScrollReporter(
            child: CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 64)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context).maybePop(),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: paperRaised,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: const Icon(
                              CupertinoIcons.chevron_left,
                              color: ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Albums',
                            style: TextStyle(
                              fontFamily: 'ArchSerif',
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                        LibraryCornerCluster(
                          leftIcon: CupertinoIcons.line_horizontal_3_decrease,
                          leftColor: ink,
                          onLeft: _pickSort,
                          onMenu: _openViewMenu,
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                SliverToBoxAdapter(
                  child: LibraryCollapsingSearch(
                    hint: 'Search albums',
                    onChanged: (q) =>
                        ref.read(libraryQueryProvider.notifier).state = q,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Expanded(
                          child: LibraryActionPill(
                            icon: CupertinoIcons.play_fill,
                            label: 'Play',
                            onTap: albums.isEmpty
                                ? null
                                : () => _playAll(albums),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: LibraryActionPill(
                            icon: CupertinoIcons.shuffle,
                            label: 'Shuffle',
                            onTap: albums.isEmpty
                                ? null
                                : () => _shuffleAll(albums),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 14)),
                if (albums.isEmpty)
                  const SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          'No albums match.',
                          style: TextStyle(color: inkDim),
                        ),
                      ),
                    ),
                  )
                else if (_grid)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverGrid.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 20,
                        mainAxisExtent:
                            (MediaQuery.sizeOf(context).width - 56) / 2 + 46,
                      ),
                      itemCount: albums.length,
                      itemBuilder: (context, i) => AlbumGridCard(
                        album: albums[i],
                        subtitle: albums[i].artist,
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverList.builder(
                      itemCount: albums.length,
                      itemBuilder: (context, i) => AlbumRow(album: albums[i]),
                    ),
                  ),
                SliverToBoxAdapter(child: SizedBox(height: bottomClear)),
              ],
            ),
          ),
          const NowPlayingDock(),
        ],
      ),
    );
  }
}
