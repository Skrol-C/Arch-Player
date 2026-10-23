import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../needle/catalog_store.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../shell/dock.dart';
import 'albums_page.dart';
import 'artists_page.dart';
import 'catalog_page.dart';
import 'library_providers.dart';
import 'library_search_page.dart';
import 'playlists_page.dart';
import 'playlists_providers.dart';
import 'song_row.dart' show FileArtImage;
import 'song_select.dart';
import 'songs_page.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
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

  @override
  Widget build(BuildContext context) {
    final songs = ref.watch(songsProvider);
    return songs.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator(color: archPink)),
      ),
      error: (e, _) {
        ArchLog.e('library', 'scan failed: $e');
        return Scaffold(body: Center(child: Text('Scan failed: $e')));
      },
      data: (_) => PopScope(
        canPop: !_sel.armed,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _sel.armed) _sel.exit();
        },
        child: _LibraryBody(sel: _sel),
      ),
    );
  }
}

/// Apple-style index: one list row per category, count on the right,
/// chevron through to the dedicated page. No search, no sorts, no
/// collages here — discovery lives on Home, browsing lives below.
class _LibraryBody extends ConsumerWidget {
  final SelectionController sel;
  const _LibraryBody({required this.sel});

  Future<void> _tapRecent(
    WidgetRef ref,
    BuildContext context,
    Song song,
    List<Song> recent,
  ) async {
    if (sel.armed) {
      HapticFeedback.selectionClick();
      sel.toggle(song.id);
      return;
    }
    HapticFeedback.selectionClick();
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playSong(song, recent));
  }

  void _holdRecent(Song song) {
    if (sel.armed) return;
    HapticFeedback.mediumImpact();
    sel.enter(song.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(songsProvider).value ?? [];
    final recent = ref.watch(recentlyAddedProvider);
    final albums = ref.watch(albumsProvider);
    final artists = {
      for (final s in songs)
        for (final a in splitArtists(s.artist))
          if (a.trim().isNotEmpty && !isUnknownSlot(a))
            a.trim().toLowerCase(): a.trim(),
    };
    final collapsed = ref.watch(pillCollapsedProvider);
    final selecting = sel.armed;
    // Select mode owns the bottom edge: the docked sheet replaces
    // the pill, so clearance is the sheet — not the dock.
    final bottomClear = selecting
        ? 380.0
        : collapsed
        ? 120.0
        : (ref.watch(miniVisibleProvider) ? 200.0 : 140.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 64)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Library',
                    style: TextStyle(
                      fontFamily: 'ArchSerif',
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const LibrarySearchPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.search_rounded, color: ink),
                  tooltip: 'Search library',
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        SliverToBoxAdapter(
          child: Column(
            children: [
              _IndexRow(
                icon: CupertinoIcons.person_2_fill,
                label: 'Artists',
                count: artists.length,
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref.read(libraryQueryProvider.notifier).state = '';
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ArtistsPage()),
                  );
                },
              ),
              _IndexRow(
                icon: CupertinoIcons.square_stack_fill,
                label: 'Albums',
                count: albums.length,
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref.read(libraryQueryProvider.notifier).state = '';
                  Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const AlbumsPage()));
                },
              ),
              _IndexRow(
                icon: CupertinoIcons.music_note_2,
                label: 'Songs',
                count: songs.length,
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref.read(libraryQueryProvider.notifier).state = '';
                  Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const SongsPage()));
                },
              ),
              _IndexRow(
                icon: CupertinoIcons.music_note_list,
                label: 'Playlists',
                count: ref.watch(playlistsProvider).length,
                onTap: () {
                  HapticFeedback.selectionClick();
                  PlaylistsPage.open(context);
                },
              ),
              _IndexRow(
                icon: CupertinoIcons.archivebox_fill,
                label: 'Catalog',
                count: ref.watch(catalogProvider).length,
                onTap: () {
                  HapticFeedback.selectionClick();
                  CatalogPage.open(context);
                },
              ),
            ],
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Recently Added',
              style: TextStyle(
                fontFamily: 'ArchSerif',
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        _RecentGrid(
          recent: recent,
          selecting: selecting,
          isSelected: (id) => sel.ids.contains(id),
          onTap: (song) => _tapRecent(ref, context, song, recent),
          onHold: _holdRecent,
        ),
        SliverToBoxAdapter(child: SizedBox(height: bottomClear)),
      ],
        ),
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
                  controller: sel,
                  ordered: () => ref.read(recentlyAddedProvider),
                  onExit: () => sel.exit(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Recently Added as a direct sliver grid (same tile grammar as
/// the Songs grid, no nested scrollable): hold arms select, taps
/// toggle while armed, check badges mark the picked.
class _RecentGrid extends ConsumerWidget {
  final List<Song> recent;
  final bool selecting;
  final bool Function(int id) isSelected;
  final void Function(Song song) onTap;
  final void Function(Song song) onHold;

  const _RecentGrid({
    required this.recent,
    required this.selecting,
    required this.isSelected,
    required this.onTap,
    required this.onHold,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (recent.isEmpty) return const SliverToBoxAdapter();
    final current = ref.watch(currentSongProvider).value;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 20,
          mainAxisExtent: (MediaQuery.sizeOf(context).width - 56) / 2 + 46,
        ),
        itemCount: recent.length,
        itemBuilder: (context, i) {
          final song = recent[i];
          final selected = song.id == current?.id;
          final checked = selecting && isSelected(song.id);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onTap(song),
            onLongPress: selecting
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    onHold(song);
                  },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: selected
                              ? Border.all(color: archPink, width: 2)
                              : null,
                        ),
                        child: FileArtImage(
                          path: song.path,
                          albumId: song.albumId,
                          fill: true,
                          radius: 16,
                        ),
                      ),
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
                    fontWeight: FontWeight.w600,
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
          );
        },
      ),
    );
  }
}

/// One index row: accent glyph, label, count, chevron. Hairline
/// dividers between rows, Apple-style.
class _IndexRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;
  const _IndexRow({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              children: [
                Icon(icon, color: archPink, size: 24),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: const TextStyle(color: inkDim, fontSize: 14),
                ),
                const SizedBox(width: 4),
                const Icon(
                  CupertinoIcons.chevron_right,
                  color: inkDim,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
        const Divider(
          height: 1,
          thickness: 1,
          indent: 78,
          endIndent: 20,
          color: Color(0x140B0B0D),
        ),
      ],
    );
  }
}
