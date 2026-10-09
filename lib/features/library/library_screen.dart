import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import 'artist_page.dart';
import 'folder_sheet.dart';
import 'library_providers.dart';
import 'shelves.dart';
import 'song_row.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(songsProvider);
    return songs.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator(color: archPink))),
      error: (e, _) {
        ArchLog.e('library', 'scan failed: $e');
        return Scaffold(body: Center(child: Text('Scan failed: $e')));
      },
      data: (_) => const _LibraryBody(),
    );
  }
}

class _LibraryBody extends ConsumerWidget {
  const _LibraryBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(libraryTabProvider);
    final view = ref.watch(libraryViewProvider);
    final visible = ref.watch(visibleSongsProvider);
    final current = ref.watch(currentSongProvider).value;
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 64)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                FocalEntrance(
                  child: Text('Library', style: Theme.of(context).textTheme.headlineLarge),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => showModalBottomSheet(
                    context: context,
                    builder: (_) => const FolderSheet(),
                  ),
                  icon: const Icon(Icons.folder_rounded),
                  color: ink,
                  tooltip: 'Folders',
                ),
                IconButton(
                  onPressed: () {
                    final v = ref.read(libraryViewProvider);
                    ref.read(libraryViewProvider.notifier).state =
                        v == ViewMode.grid ? ViewMode.list : ViewMode.grid;
                  },
                  icon: Icon(view == ViewMode.grid ? Icons.view_list_rounded : Icons.grid_view_rounded),
                  color: ink,
                  tooltip: 'Grid / list',
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SearchBar(
              hintText: 'Search songs, artists, albums',
              backgroundColor: const WidgetStatePropertyAll(paperRaised),
              elevation: const WidgetStatePropertyAll(0),
              onChanged: (q) => ref.read(libraryQueryProvider.notifier).state = q,
            ),
          ),
        ),
        SliverToBoxAdapter(child: _SortRow()),
        SliverToBoxAdapter(child: _TabPills()),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        const SliverToBoxAdapter(child: Shelves()),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        if (visible.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('No songs — check Folders.', style: TextStyle(color: inkDim))),
          )
        else if (tab == LibraryTab.songs)
          view == ViewMode.grid ? _SongGrid(currentId: current?.id) : _SongList(currentId: current?.id)
        else if (tab == LibraryTab.albums)
          _AlbumGrid(currentId: current?.id)
        else
          const _ArtistList(),
        const SliverToBoxAdapter(child: SizedBox(height: 140)),
      ],
    );
  }
}

class _SortRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sort = ref.watch(librarySortProvider);
    Widget chip(String label, SortOrder order) => FilterChip(
          label: Text(label),
          selected: sort == order,
          selectedColor: archPink.withValues(alpha: 0.15),
          checkmarkColor: archPink,
          onSelected: (_) => ref.read(librarySortProvider.notifier).state = order,
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 8,
        children: [
          chip('Title', SortOrder.title),
          chip('Artist', SortOrder.artist),
          chip('Recent', SortOrder.recent)
        ],
      ),
    );
  }
}

class _TabPills extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(libraryTabProvider);
    Widget pill(String label, LibraryTab t) {
      final selected = tab == t;
      return GestureDetector(
        onTap: () => ref.read(libraryTabProvider.notifier).state = t,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? archPink : paperRaised,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Text(label,
              style: TextStyle(
                  color: selected ? Colors.white : ink, fontWeight: FontWeight.w600)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          pill('Songs', LibraryTab.songs),
          const SizedBox(width: 8),
          pill('Albums', LibraryTab.albums),
          const SizedBox(width: 8),
          pill('Artists', LibraryTab.artists),
        ],
      ),
    );
  }
}

Future<void> _tapToPlay(WidgetRef ref, BuildContext context, Song song, List<Song> queue) async {
  final handler = ref.read(audioHandlerProvider);
  final opener = ref.read(playerOpenProvider.notifier);
  await playGuarded(context, () => handler.playSong(song, queue));
  opener.state = true;
}

class _SongList extends ConsumerWidget {
  final int? currentId;
  const _SongList({required this.currentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(visibleSongsProvider);
    return SliverList.builder(
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final song = visible[i];
        return SongRow(
          song: song,
          art: AlbumArt(albumId: song.albumId),
          isCurrent: song.id == currentId,
          onTap: () => _tapToPlay(ref, context, song, visible),
        );
      },
    );
  }
}

class _SongGrid extends ConsumerWidget {
  final int? currentId;
  const _SongGrid({required this.currentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(visibleSongsProvider);
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 20,
          childAspectRatio: 0.78,
        ),
        itemCount: visible.length,
        itemBuilder: (context, i) {
          final song = visible[i];
          final selected = song.id == currentId;
          return GestureDetector(
            onTap: () => _tapToPlay(ref, context, song, visible),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: selected ? Border.all(color: archPink, width: 2) : null,
                    ),
                    child: AlbumArt(albumId: song.albumId, fill: true, radius: 16),
                  ),
                ),
                const SizedBox(height: 6),
                Text(song.title,
                    maxLines: 1,
                    style: TextStyle(
                        color: selected ? archPink : ink, fontWeight: FontWeight.w600)),
                Text(song.artist, maxLines: 1, style: const TextStyle(color: inkDim, fontSize: 13)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _AlbumGrid extends ConsumerWidget {
  final int? currentId;
  const _AlbumGrid({required this.currentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(albumsProvider);
    if (albums.isEmpty) {
      return const SliverToBoxAdapter(
          child: Center(child: Text('No albums match.', style: TextStyle(color: inkDim))));
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 20,
          childAspectRatio: 0.78,
        ),
        itemCount: albums.length,
        itemBuilder: (context, i) {
          final album = albums[i];
          return GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => AlbumDetail(album: album),
            )),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: AlbumArt(albumId: album.songs.first.albumId, fill: true, radius: 16)),
                const SizedBox(height: 6),
                Text(album.title, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(album.artist,
                    maxLines: 1, style: const TextStyle(color: inkDim, fontSize: 13)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class AlbumDetail extends ConsumerWidget {
  final Album album;
  const AlbumDetail({super.key, required this.album});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(currentSongProvider).value;
    final songs = album.songs;
    return Scaffold(
      appBar: AppBar(title: const Text('Album')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                AlbumArt(albumId: songs.first.albumId, size: 128, radius: 16),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(album.title, style: Theme.of(context).textTheme.headlineSmall),
                      Text(album.artist, style: const TextStyle(color: archPink)),
                      Text('${songs.length} songs', style: const TextStyle(color: inkDim)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          for (final song in songs)
            SongRow(
              song: song,
              art: AlbumArt(albumId: song.albumId),
              isCurrent: song.id == current?.id,
              onTap: () => _tapToPlay(ref, context, song, songs),
            ),
        ],
      ),
    );
  }
}

class _ArtistList extends ConsumerWidget {
  const _ArtistList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(artistsProvider);
    final followed = ref.watch(followedProvider);
    if (artists.isEmpty) {
      return const SliverToBoxAdapter(
          child: Center(child: Text('No artists match.', style: TextStyle(color: inkDim))));
    }
    return SliverList.builder(
      itemCount: artists.length,
      itemBuilder: (context, i) {
        final entry = artists[i];
        final isFollowed = followed.contains(entry.name);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          onTap: () => ArtistPage.openIfAbsent(context, entry.name),
          leading: const CircleAvatar(
              radius: 26, backgroundColor: paperRaised, child: Icon(Icons.person, color: inkDim)),
          title: Text(entry.name, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text('${entry.songs.length} songs', style: const TextStyle(color: inkDim)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isFollowed) const Icon(Icons.check_circle, color: archPink, size: 20),
              TextButton(
                onPressed: () => ref.read(followedProvider.notifier).toggle(entry.name),
                child: Text(isFollowed ? 'Following' : 'Follow'),
              ),
              const Icon(Icons.chevron_right_rounded, color: inkDim),
            ],
          ),
        );
      },
    );
  }
}
