import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../player/track_menu.dart';
import '../shell/dock.dart';

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
    // Clearance follows the docked unit so content never slides
    // under it: collapsed unit is short, mini + pill is tall.
    final collapsed = ref.watch(pillCollapsedProvider);
    final bottomClear =
        collapsed ? 120.0 : (ref.watch(miniVisibleProvider) ? 200.0 : 140.0);
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
            child: Center(child: Text('No songs - check Folders.', style: TextStyle(color: inkDim))),
          )
        else if (tab == LibraryTab.songs)
          view == ViewMode.grid ? _SongGrid(currentId: current?.id) : _SongList(currentId: current?.id)
        else if (tab == LibraryTab.albums)
          _AlbumGrid(currentId: current?.id)
        else
          const _ArtistList(),
        SliverToBoxAdapter(child: SizedBox(height: bottomClear)),
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
  await playAndOpen(ref, context, () => handler.playSong(song, queue));
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
              builder: (_) => AlbumPage(album: album),
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

/// A real album page: big art hero, voiced title, tappable artist,
/// Play + shuffle, indexed tracklist with per-row menus. Reached from
/// grids, featured card, gallery tiles, Popular overflow, and track
/// menus - never a dead tap, never a bare list.
class AlbumPage extends ConsumerWidget {
  final Album album;
  const AlbumPage({super.key, required this.album});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(currentSongProvider).value;
    final songs = album.songs;
    // Mount footprint: proves which build is on the phone and what
    // data arrived. Silence here means the route never built.
    ArchLog.i('nav',
        'album page: ${album.title} (${songs.length} tracks)');
    // Empty can technically arrive (stale queue entry, moved files):
    // an explicit empty state, never a blank page or a crash on
    // songs.first.
    if (songs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Album')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.album_outlined, color: inkDim, size: 64),
              const SizedBox(height: 12),
              Text(album.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('No songs found for this album.',
                  style: TextStyle(color: inkDim)),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Go back',
                    style: TextStyle(
                        color: archPink, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      );
    }
    Future<void> play(bool shuffleFirst) async {
      final handler = ref.read(audioHandlerProvider);
      // Fire-and-forget: shuffle applies to the live player while the
      // guarded entry below owns the context across its own awaits.
      if (shuffleFirst) unawaited(handler.setShuffleEnabled(true));
      await playAndOpen(
          ref, context, () => handler.playSong(songs.first, songs));
    }

    final total = songs.fold(
        Duration.zero, (sum, s) => sum + s.duration);
    return Scaffold(
      appBar: AppBar(title: const Text('Album')),
      body: DockScrollReporter(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ListView(
              padding: const EdgeInsets.only(bottom: 140),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                  child: Column(
                    children: [
                      FocalEntrance(
                        // Bounded square: fill art needs finite height
                        // and this Column offers infinity. Unbounded here
                        // lays out never and blanks the page in release.
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: const [
                                BoxShadow(
                                    color: Color(0x1A000000),
                                    blurRadius: 28,
                                    offset: Offset(0, 10)),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: AlbumArt(
                                  albumId: songs.first.albumId,
                                  fill: true,
                                  radius: 0,
                                  detail: true),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(album.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontFamily: artistVoiceOf(album.title),
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              letterSpacing: voiceSpacing(
                                  artistVoiceOf(album.title)))),
                      GestureDetector(
                        onTap: () => ArtistPage.openIfAbsent(
                            context, album.artist),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(album.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: archPink,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                          '${songs.length} song${songs.length == 1 ? '' : 's'} - ${fmtDuration(total)}',
                          style: const TextStyle(color: inkDim)),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          GestureDetector(
                            onTap: () {
                              HapticFeedback.mediumImpact();
                              play(false);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 40, vertical: 14),
                              decoration: const BoxDecoration(
                                color: archPink,
                                borderRadius:
                                    BorderRadius.all(Radius.circular(28)),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.play_arrow_rounded,
                                      color: Colors.white, size: 24),
                                  SizedBox(width: 4),
                                  Text('Play',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          GestureDetector(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              play(true);
                            },
                            child: Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: paperRaised,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: ink.withValues(alpha: 0.08)),
                              ),
                              child: const Icon(Icons.shuffle_rounded,
                                  color: ink, size: 24),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < songs.length; i++)
                  _AlbumTrackRow(
                    song: songs[i],
                    queue: songs,
                    index: i + 1,
                    isCurrent: songs[i].id == current?.id,
                  ),
              ],
            ),
            const NowPlayingDock(),
          ],
        ),
      ),
    );
  }
}

class _AlbumTrackRow extends ConsumerWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  final bool isCurrent;

  const _AlbumTrackRow(
      {required this.song,
      required this.queue,
      required this.index,
      required this.isCurrent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      onTap: () => _tapToPlay(ref, context, song, queue),
      leading: SizedBox(
        width: 30,
        child: Text('$index',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: isCurrent ? archPink : inkDim,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
      ),
      title: Text(song.title,
          maxLines: 1,
          style: TextStyle(
              color: isCurrent ? archPink : ink,
              fontWeight: FontWeight.w600)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrent) const NowBars() else Text(fmtDuration(song.duration), style: const TextStyle(color: inkDim)),
          IconButton(
            icon: const Icon(Icons.more_horiz_rounded, color: inkDim),
            onPressed: () => showSongMenu(ref, context, song),
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
