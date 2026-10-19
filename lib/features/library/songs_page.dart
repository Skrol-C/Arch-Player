import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../player/track_menu.dart' show MenuAction, showSongMenu, showTrackMenu;
import '../shell/dock.dart';
import 'library_chrome.dart';
import 'library_controls.dart';
import 'library_providers.dart';
import 'song_row.dart';

/// Songs index (WA0009 grammar): back, sort capsule + `...`, search,
/// Play / Shuffle, then every track as a row (with its own `...`) or
/// as covers. `...` owns the view switch; the left half owns sort.
class SongsPage extends ConsumerStatefulWidget {
  const SongsPage({super.key});

  @override
  ConsumerState<SongsPage> createState() => _SongsPageState();
}

class _SongsPageState extends ConsumerState<SongsPage> {
  Future<void> _playAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    HapticFeedback.mediumImpact();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playSong(songs.first, songs));
  }

  Future<void> _shuffleAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    final queue = List<Song>.of(songs)..shuffle();
    HapticFeedback.mediumImpact();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playSong(queue.first, queue));
  }

  Future<void> _pickSort() async {
    final value = await showLibrarySort<SortOrder>(
      context: context,
      current: ref.read(librarySortProvider),
      options: const [
        (label: 'Title', value: SortOrder.title),
        (label: 'Artist', value: SortOrder.artist),
        (label: 'Year', value: SortOrder.recent),
      ],
    );
    if (!mounted || value == null) return;
    ref.read(librarySortProvider.notifier).state = value;
  }

  Future<void> _openViewMenu(BuildContext buttonContext) async {
    final view = ref.read(libraryViewProvider);
    final value = await showTrackMenu(
      context: buttonContext,
      groups: [
        [
          MenuAction(
            icon: CupertinoIcons.square_grid_2x2,
            label: 'Grid',
            value: 'grid',
            selected: view == ViewMode.grid,
          ),
          MenuAction(
            icon: CupertinoIcons.list_bullet,
            label: 'List',
            value: 'list',
            selected: view == ViewMode.list,
          ),
        ],
      ],
    );
    if (!mounted) return;
    final ViewMode? want = switch (value) {
      'grid' => ViewMode.grid,
      'list' => ViewMode.list,
      _ => null,
    };
    if (want == null || want == view) return;
    HapticFeedback.selectionClick();
    ref.read(libraryViewProvider.notifier).state = want;
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(libraryViewProvider);
    final visible = ref.watch(visibleSongsProvider);
    final current = ref.watch(currentSongProvider).value;
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
                            'Songs',
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
                    hint: 'Search songs',
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
                            onTap: visible.isEmpty
                                ? null
                                : () => _playAll(visible),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: LibraryActionPill(
                            icon: CupertinoIcons.shuffle,
                            label: 'Shuffle',
                            onTap: visible.isEmpty
                                ? null
                                : () => _shuffleAll(visible),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 10)),
                if (view == ViewMode.grid)
                  _SongGrid(currentId: current?.id, songs: visible)
                else
                  _SongList(currentId: current?.id, songs: visible),
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

Future<void> _tapToPlay(
  WidgetRef ref,
  BuildContext context,
  Song song,
  List<Song> queue,
) async {
  final handler = ref.read(audioHandlerProvider);
  await playAndOpen(ref, context, () => handler.playSong(song, queue));
}

class _SongList extends ConsumerWidget {
  final int? currentId;
  final List<Song> songs;
  const _SongList({required this.currentId, required this.songs});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (songs.isEmpty) {
      return const SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Text('No songs match.', style: TextStyle(color: inkDim)),
          ),
        ),
      );
    }
    return SliverList.builder(
      itemCount: songs.length,
      itemBuilder: (context, i) {
        final song = songs[i];
        return SongRow(
          song: song,
          isCurrent: song.id == currentId,
          onTap: () => _tapToPlay(ref, context, song, songs),
          onMore: () => showSongMenu(ref, context, song),
        );
      },
    );
  }
}

class _SongGrid extends ConsumerWidget {
  final int? currentId;
  final List<Song> songs;
  const _SongGrid({required this.currentId, required this.songs});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (songs.isEmpty) {
      return const SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Text('No songs match.', style: TextStyle(color: inkDim)),
          ),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 20,
          // Measured extent, not a ratio: a ratio rounds and the tile
          // overflows by a fraction of a pixel.
          mainAxisExtent: (MediaQuery.sizeOf(context).width - 56) / 2 + 46,
        ),
        itemCount: songs.length,
        itemBuilder: (context, i) {
          final song = songs[i];
          final selected = song.id == currentId;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _tapToPlay(ref, context, song, songs),
            onLongPress: () => showSongMenu(ref, context, song),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: selected
                          ? Border.all(color: archPink, width: 2)
                          : null,
                    ),
                    child: FileArtImage(
                      path: song.path,
                      albumId: song.albumId,
                      size: 160,
                      radius: 18,
                      fill: true,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? archPink : ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: inkDim, fontSize: 12),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
