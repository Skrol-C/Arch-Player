import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import 'folder_sheet.dart';
import 'library_providers.dart';
import 'song_row.dart';

/// Library shelves: hero deck, category tiles, art rails. Shown only when
/// no search query is active - searching shows flat results instead.
/// Art leads everywhere; text stays small and quiet.
class Shelves extends ConsumerWidget {
  const Shelves({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(libraryQueryProvider);
    if (query.trim().isNotEmpty) return const SizedBox.shrink();
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: 4),
        _HeroDeck(),
        SizedBox(height: 8),
        _CategoryTiles(),
        _RecentlyAddedRail(),
        _ListenAgainRail(),
        _FollowedRail(),
      ],
    );
  }
}

class _HeroDeck extends ConsumerWidget {
  const _HeroDeck();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentlyAddedProvider);
    final again = ref.watch(listenAgainProvider).value ?? [];
    final cards = <_HeroCard>[];
    if (recent.isNotEmpty) {
      final albumSongs = recent
          .where((s) => s.album == recent.first.album)
          .toList();
      cards.add(
        _HeroCard(
          kicker: 'New to you',
          title: recent.first.album,
          subtitle: recent.first.artist,
          songs: albumSongs.isEmpty ? [recent.first] : albumSongs,
        ),
      );
    }
    if (again.isNotEmpty) {
      cards.add(
        _HeroCard(
          kicker: 'Listen again',
          title: again.first.title,
          subtitle: again.first.artist,
          songs: [again.first],
        ),
      );
    }
    if (cards.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 220,
      child: PageView.builder(
        controller: PageController(viewportFraction: 0.88),
        itemCount: cards.length,
        itemBuilder: (context, i) =>
            Padding(padding: const EdgeInsets.only(right: 12), child: cards[i]),
      ),
    );
  }
}

class _HeroCard extends ConsumerWidget {
  final String kicker;
  final String title;
  final String subtitle;
  final List<Song> songs;

  const _HeroCard({
    required this.kicker,
    required this.title,
    required this.subtitle,
    required this.songs,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artId = songs.first.albumId;
    return GestureDetector(
      onTap: () async {
        final handler = ref.read(audioHandlerProvider);
        await playAndOpen(
          ref,
          context,
          () => handler.playSong(songs.first, songs),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: paperRaised,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 20,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            FileArtImage(
                path: songs.first.path,
                albumId: artId,
                size: 140,
                radius: 16),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    kicker.toUpperCase(),
                    style: const TextStyle(
                      color: archPink,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    title,
                    maxLines: 2,
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    style: const TextStyle(color: inkDim),
                  ),
                  const SizedBox(height: 12),
                  const Icon(
                    Icons.play_circle_fill_rounded,
                    color: archPink,
                    size: 40,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryTiles extends ConsumerWidget {
  const _CategoryTiles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(songsProvider).value ?? [];
    final albums = ref.watch(albumsProvider);
    final artists = ref.watch(artistsProvider);
    Widget tile(String label, int count, List<int> artIds, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: paperRaised,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                        ),
                    itemCount: 4,
                    itemBuilder: (context, i) => i < artIds.length
                        ? AlbumArt(albumId: artIds[i], fill: true, radius: 0)
                        : Container(color: paper),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(
                '$count',
                style: const TextStyle(color: inkDim, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    List<int> artOf(List<Song> list) =>
        list.take(4).map((s) => s.albumId).toList();
    final tab = ref.watch(libraryTabProvider);
    void go(LibraryTab t) {
      ref.read(libraryTabProvider.notifier).state = t;
      if (tab == t) return;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.15,
        children: [
          tile('Songs', songs.length, artOf(songs), () => go(LibraryTab.songs)),
          tile(
            'Albums',
            albums.length,
            artOf([for (final a in albums) ...a.songs]),
            () => go(LibraryTab.albums),
          ),
          tile(
            'Artists',
            artists.length,
            artOf(songs),
            () => go(LibraryTab.artists),
          ),
          tile('Folders', ref.watch(foldersProvider).length, artOf(songs), () {
            showModalBottomSheet(
              context: context,
              builder: (_) => const FolderSheet(),
            );
          }),
        ],
      ),
    );
  }
}

class _RailShell extends StatelessWidget {
  final String title;
  final List<Song> songs;
  final bool showNewBadge;

  const _RailShell({
    required this.title,
    required this.songs,
    this.showNewBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) return const SizedBox.shrink();
    final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        SizedBox(
          height: 168,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: songs.length,
            itemBuilder: (context, i) {
              final song = songs[i];
              final isNew =
                  showNewBadge &&
                  nowSecs - song.addedSecs < 7 * 24 * 3600 &&
                  song.addedSecs > 0;
              return _RailCard(song: song, isNew: isNew, index: i);
            },
          ),
        ),
      ],
    );
  }
}

class _RailCard extends ConsumerWidget {
  final Song song;
  final bool isNew;
  final int index;

  const _RailCard({
    required this.song,
    required this.isNew,
    required this.index,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FocalEntrance(
      index: index,
      child: GestureDetector(
        onTap: () async {
          final handler = ref.read(audioHandlerProvider);
          final all = ref.read(songsProvider).value ?? [song];
          await playAndOpen(ref, context, () => handler.playSong(song, all));
        },
        child: Container(
          width: 120,
          margin: const EdgeInsets.only(right: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FileArtImage(
                  path: song.path,
                  albumId: song.albumId,
                  size: 120,
                  radius: 16),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (isNew)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Text(
                        'NEW',
                        style: TextStyle(
                          color: archPink,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Text(
                      song.title,
                      maxLines: 1,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                song.artist,
                maxLines: 1,
                style: const TextStyle(color: inkDim, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentlyAddedRail extends ConsumerWidget {
  const _RecentlyAddedRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _RailShell(
      title: 'Recently Added',
      songs: ref.watch(recentlyAddedProvider),
      showNewBadge: true,
    );
  }
}

class _ListenAgainRail extends ConsumerWidget {
  const _ListenAgainRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final again = ref.watch(listenAgainProvider).value ?? [];
    return _RailShell(title: 'Listen Again', songs: again);
  }
}

class _FollowedRail extends ConsumerWidget {
  const _FollowedRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final followed = ref.watch(followedProvider);
    final artists = ref.watch(artistsProvider);
    final mine = artists.where((a) => followed.contains(a.name)).toList();
    if (mine.isEmpty) return const SizedBox.shrink();
    final songs = [for (final a in mine) ...a.songs.take(3)].take(12).toList();
    return _RailShell(title: 'From Artists You Follow', songs: songs);
  }
}
