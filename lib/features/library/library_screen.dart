import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../player/player_providers.dart';
import 'artist_page.dart';
import 'folder_sheet.dart';
import 'library_providers.dart';
import 'song_row.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(songsProvider);
    return songs.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator(color: archRed))),
      error: (e, _) => Scaffold(body: Center(child: Text('Scan failed: $e'))),
      data: (_) => const _LibraryBody(),
    );
  }
}

class _LibraryBody extends ConsumerWidget {
  const _LibraryBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(libraryTabProvider);
    final visible = ref.watch(visibleSongsProvider);
    final current = ref.watch(currentSongProvider).value;
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 56)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text('Library', style: Theme.of(context).textTheme.headlineLarge),
                const Spacer(),
                TextButton(
                  onPressed: () => showModalBottomSheet(
                    context: context,
                    builder: (_) => const FolderSheet(),
                  ),
                  child: const Text('Folders'),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SearchBar(
              hintText: 'Search songs, artists, albums',
              onChanged: (q) => ref.read(libraryQueryProvider.notifier).state = q,
            ),
          ),
        ),
        SliverToBoxAdapter(child: _SortRow()),
        SliverToBoxAdapter(child: _TabPills()),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        if (visible.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('No songs — check Folders.')),
          )
        else if (tab == LibraryTab.songs)
          SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (context, i) {
              final song = visible[i];
              return SongRow(
                song: song,
                art: AlbumArt(albumId: song.albumId),
                isCurrent: song.id == current?.id,
                onTap: () async {
                  final handler = ref.read(audioHandlerProvider);
                  final opener = ref.read(playerOpenProvider.notifier);
                  await handler.playSong(song, visible);
                  opener.state = true;
                },
              );
            },
          )
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
          selectedColor: archRed.withValues(alpha: 0.25),
          onSelected: (_) => ref.read(librarySortProvider.notifier).state = order,
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
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
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? archRed : inkRaised,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(label),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
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

class _AlbumGrid extends ConsumerWidget {
  final int? currentId;
  const _AlbumGrid({required this.currentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(albumsProvider);
    if (albums.isEmpty) {
      return const SliverToBoxAdapter(child: Center(child: Text('No albums match.')));
    }
    return SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 20,
          childAspectRatio: 0.8,
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
                Expanded(
                  child: AlbumArt(albumId: album.songs.first.albumId, fill: true, radius: 12),
                ),
                const SizedBox(height: 6),
                Text(album.title, maxLines: 1, style: Theme.of(context).textTheme.bodyMedium),
                Text(album.artist,
                    maxLines: 1,
                    style:
                        Theme.of(context).textTheme.bodySmall?.copyWith(color: inkTextDim)),
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
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                AlbumArt(albumId: songs.first.albumId, size: 120, radius: 12),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(album.title, style: Theme.of(context).textTheme.headlineSmall),
                      Text(album.artist, style: const TextStyle(color: archRed)),
                      Text('${songs.length} songs', style: const TextStyle(color: inkTextDim)),
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
              onTap: () async {
                final handler = ref.read(audioHandlerProvider);
                final opener = ref.read(playerOpenProvider.notifier);
                await handler.playSong(song, songs);
                opener.state = true;
              },
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
      return const SliverToBoxAdapter(child: Center(child: Text('No artists match.')));
    }
    return SliverList.builder(
      itemCount: artists.length,
      itemBuilder: (context, i) {
        final entry = artists[i];
        final isFollowed = followed.contains(entry.name);
        return ListTile(
          onTap: () => ArtistPage.openIfAbsent(context, entry.name),
          leading: const CircleAvatar(
              backgroundColor: inkRaised, child: Icon(Icons.person, color: inkTextDim)),
          title: Text(entry.name, maxLines: 1),
          subtitle: Text('${entry.songs.length} songs', style: const TextStyle(color: inkTextDim)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isFollowed) const Icon(Icons.check_circle, color: archRed, size: 20),
              TextButton(
                onPressed: () => ref.read(followedProvider.notifier).toggle(entry.name),
                child: Text(isFollowed ? 'Following' : 'Follow'),
              ),
              const Text('›', style: TextStyle(color: inkTextDim)),
            ],
          ),
        );
      },
    );
  }
}
