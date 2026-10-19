import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../needle/catalog_store.dart';
import '../player/player_providers.dart';
import '../shell/dock.dart';
import 'albums_page.dart';
import 'artists_page.dart';
import 'catalog_page.dart';
import 'library_providers.dart';
import 'library_search_page.dart';
import 'shelves.dart';
import 'songs_page.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(songsProvider);
    return songs.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator(color: archPink)),
      ),
      error: (e, _) {
        ArchLog.e('library', 'scan failed: $e');
        return Scaffold(body: Center(child: Text('Scan failed: $e')));
      },
      data: (_) => const _LibraryBody(),
    );
  }
}

/// Apple-style index: one list row per category, count on the right,
/// chevron through to the dedicated page. No search, no sorts, no
/// collages here — discovery lives on Home, browsing lives below.
class _LibraryBody extends ConsumerWidget {
  const _LibraryBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(songsProvider).value ?? [];
    final albums = ref.watch(albumsProvider);
    final artists = {
      for (final s in songs)
        for (final a in splitArtists(s.artist))
          if (a.trim().isNotEmpty && !isUnknownSlot(a))
            a.trim().toLowerCase(): a.trim(),
    };
    final collapsed = ref.watch(pillCollapsedProvider);
    final bottomClear = collapsed
        ? 120.0
        : (ref.watch(miniVisibleProvider) ? 200.0 : 140.0);
    return CustomScrollView(
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
        const SliverToBoxAdapter(child: Shelves()),
        SliverToBoxAdapter(child: SizedBox(height: bottomClear)),
      ],
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
