import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/badges.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../player/track_menu.dart' show MenuAction, showSongMenu;
import '../shell/morph_menu.dart' show showMorphMenu;
import '../shell/dock.dart';
import 'library_chrome.dart';
import 'library_controls.dart';
import 'library_providers.dart';
import 'playlists_providers.dart';
import 'song_row.dart';
import 'song_select.dart';

/// Songs index (WA0009 grammar): back, sort capsule + `...`, search,
/// Play / Shuffle, then every track as a row (with its own `...`) or
/// as covers. `...` owns the view switch; the left half owns sort.
class SongsPage extends ConsumerStatefulWidget {
  const SongsPage({super.key});

  @override
  ConsumerState<SongsPage> createState() => _SongsPageState();
}

class _SongsPageState extends ConsumerState<SongsPage> {
  final _sel = SelectionController();

  @override
  void initState() {
    super.initState();
    _sel.addListener(() {
      if (!mounted) return;
      ref.read(selectionActiveProvider.notifier).state = _sel.armed;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _sel.dispose();
    super.dispose();
  }

  /// Hold enters select mode: the held song checks, boxes appear,
  /// the one-row bar slides up. Tap toggles; exit is explicit.
  Future<void> _enterSelect(Song first) async {
    if (_sel.armed) return;
    HapticFeedback.mediumImpact();
    _sel.enter(first.id);
  }

  Future<void> _tapSong(Song song, List<Song> queue) async {
    if (_sel.armed) {
      HapticFeedback.selectionClick();
      _sel.toggle(song.id);
      return;
    }
    await _tapToPlay(ref, context, song, queue);
  }

  Future<void> _playAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    HapticFeedback.mediumImpact();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playSong(songs.first, songs));
  }

  Future<void> _shuffleAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    HapticFeedback.mediumImpact();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playShuffled(songs));
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
    final value = await showMorphMenu(
      context: buttonContext,
      items: [
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
    final selecting = _sel.armed;
    final collapsed = ref.watch(pillCollapsedProvider);
    final bottomClear = selecting
        ? 380.0
        : collapsed
        ? 120.0
        : (ref.watch(miniVisibleProvider) ? 200.0 : 140.0);
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) _sel.exit();
      },
      child: Scaffold(
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
                          onTap: () => selecting
                              ? _sel.exit()
                              : Navigator.of(context).maybePop(),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: paperRaised,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Icon(
                              selecting
                                  ? CupertinoIcons.xmark
                                  : CupertinoIcons.chevron_left,
                              color: ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            selecting
                                ? '${_sel.count} selected'
                                : 'Songs',
                            style: const TextStyle(
                              fontFamily: 'ArchSerif',
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                        if (selecting)
                          TextButton(
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              Navigator.of(context).maybePop();
                              _sel.exit();
                            },
                            child: const Text(
                              'Done',
                              style: TextStyle(
                                color: archPink,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        else
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
                  _SongGrid(
                    currentId: current?.id,
                    songs: visible,
                    selecting: selecting,
                    isSelected: (id) => _sel.ids.contains(id),
                    onTap: (s) => _tapSong(s, visible),
                    onHold: _enterSelect,
                  )
                else
                  _SongList(
                    currentId: current?.id,
                    songs: visible,
                    selecting: selecting,
                    isSelected: (id) => _sel.ids.contains(id),
                    onTap: (s) => _tapSong(s, visible),
                    onHold: _enterSelect,
                  ),
                SliverToBoxAdapter(child: SizedBox(height: bottomClear)),
              ],
            ),
          ),
          if (!selecting) const NowPlayingDock(),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: AnimatedSlide(
              duration: Motion.reduced(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 350),
              curve: Motion.arrival,
              offset: selecting ? Offset.zero : const Offset(0, 2),
              child: AnimatedOpacity(
                duration: Motion.reduced(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 250),
                opacity: selecting ? 1 : 0,
                child: IgnorePointer(
                  ignoring: !selecting,
                  child: SelectionSheet(
                    controller: _sel,
                    ordered: () => visible,
                    onExit: () => _sel.exit(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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
  final bool selecting;
  final bool Function(int id) isSelected;
  final void Function(Song song) onTap;
  final void Function(Song song) onHold;

  const _SongList({
    required this.currentId,
    required this.songs,
    required this.selecting,
    required this.isSelected,
    required this.onTap,
    required this.onHold,
  });

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
    final membership =
        selecting ? ref.watch(playlistMembershipProvider) : null;
    return SliverList.builder(
      itemCount: songs.length,
      itemBuilder: (context, i) {
        final song = songs[i];
        return SongRow(
          song: song,
          isCurrent: song.id == currentId,
          selected: selecting ? isSelected(song.id) : null,
          containedIn: membership?[song.id],
          onTap: () => onTap(song),
          onMoreAt: selecting
              ? null
              : (btnContext) =>
                    showSongMenu(ref, btnContext, song),
          onHold: selecting ? null : () => onHold(song),
        );
      },
    );
  }
}

class _SongGrid extends ConsumerWidget {
  final int? currentId;
  final List<Song> songs;
  final bool selecting;
  final bool Function(int id) isSelected;
  final void Function(Song song) onTap;
  final void Function(Song song) onHold;

  const _SongGrid({
    required this.currentId,
    required this.songs,
    required this.selecting,
    required this.isSelected,
    required this.onTap,
    required this.onHold,
  });

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
    final membership =
        selecting ? ref.watch(playlistMembershipProvider) : null;
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
          final checked = selecting && isSelected(song.id);
          final contained = membership?[song.id];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onTap(song),
            onLongPress: selecting ? null : () => onHold(song),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    children: [
                      Container(
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
                      // Select-mode check badge, top-left on the art.
                      if (selecting)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: checked
                                  ? archPink
                                  : Colors.black.withValues(alpha: 0.35),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.8),
                                width: 2,
                              ),
                            ),
                            child: checked
                                ? const Icon(
                                    CupertinoIcons.checkmark,
                                    color: Colors.white,
                                    size: 16,
                                  )
                                : null,
                          ),
                        ),
                      // Containment badge, bottom-left on the art.
                      if (selecting &&
                          contained != null &&
                          contained.isNotEmpty)
                        Positioned(
                          bottom: 8,
                          left: 8,
                          child: ContainedBadge(names: contained),
                        ),
                      // Overflow `...`: grid had hold only until now.
                      if (!selecting)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Builder(
                            builder: (btnContext) => GestureDetector(
                              onTap: () =>
                                  showSongMenu(ref, btnContext, song),
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: paperRaised,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: ink.withValues(alpha: 0.08),
                                  ),
                                ),
                                child: const Icon(
                                  CupertinoIcons.ellipsis,
                                  color: inkDim,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
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
